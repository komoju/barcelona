require 'erb'
require 'ostruct'
require 'aws-sdk'

class ServerDecorator
  attr_accessor :hostname, :proxy_protocol, :ssl_cert_path, :ssl_key_path,
                :upstream_port, :upstream_name, :force_ssl, :disable_ssl

  def initialize(attrs)
    attrs.each do |k, v|
      instance_variable_set(:"@#{k}", v)
    end
  end

  def http_listen
    line = []
    line << "listen 80"
    line << "proxy_protocol" if proxy_protocol
    line << "default_server" if hostname == "_"
    line.join(" ")
  end

  def https_listen
    line = []
    line << "listen 443 ssl http2"
    line << "proxy_protocol" if proxy_protocol
    line << "default_server" if hostname == "_"
    line.join(" ")
  end
end

### Environement variables example
# UPSTREAM_NAME=backend.local
# UPSTREAM_PORT=3000
# HTTP_HOSTS=login.example.com,web-front.example.com
# CERT_LOGIN_EXAMPLE_COM=s3://bucket-name/login.example.com/cert
# KEY_LOGIN_EXAMPLE_COM=s3://bucket-name/login.example.com/key
# CERT_WEB__FRONT_EXAMPLE_COM=s3://bucket-name/web-front.example.com/cert
# KEY_WEB__FRONT_EXAMPLE_COM=s3://bucket-name/web-front.example.com/key

def render_template(from, to, namespace={})
  erb = ERB.new(File.read(from))
  open(to, 'w') do |f|
    f << erb.result(OpenStruct.new(namespace).instance_eval{ binding })
  end
end

def download_s3(url, dest)
  match = url.match(/\As3:\/\/(?<bucket_name>[\w-]+)\/(?<path>.+)/)
  cli = Aws::S3::Client.new
  cli.get_object(
    bucket: match[:bucket_name],
    key: match[:path],
    response_target: dest
  )
end

def server_conf_template_path
  if ENV['ALB'] == "true"
    '/templates/alb_server.conf.erb'
  else
    '/templates/server.conf.erb'
  end
end

def default_log_format
  <<~LOG_FORMAT
    '$proxy_protocol_addr - [$time_local] '
    '"$request" $status $body_bytes_sent '
    '"$http_referer" "$http_user_agent"'
    'rt=$request_time uct="$upstream_connect_time" uht="$upstream_header_time" urt="$upstream_response_time"'
  LOG_FORMAT
end

def no_query_params_log_format
  <<~LOG_FORMAT
    '$proxy_protocol_addr - [$time_local] '
    '"$request_method $uri $server_protocol" $status $body_bytes_sent '
    '"$http_user_agent"'
    'rt=$request_time uct="$upstream_connect_time" uht="$upstream_header_time" urt="$upstream_response_time" '
    '"trace-id=$http_x_amzn_trace_id"'
  LOG_FORMAT
end

def log_format
  ENV['REMOVE_PARAMS_FROM_LOGS'] == 'true' ? no_query_params_log_format : default_log_format
end

render_template('/templates/nginx.conf.erb', '/etc/nginx/nginx.conf',
                upstream_name: ENV['UPSTREAM_NAME'],
                upstream_port: ENV['UPSTREAM_PORT'],
                log_format: log_format,
)

hosts = (ENV['HTTP_HOSTS'] || "").split(',')
hosts.each do |host|
  host_key = host.gsub('.', '_').gsub('-', '__').upcase
  s3_ssl_cert_path = ENV["CERT_#{host_key}"]
  s3_ssl_key_path = ENV["KEY_#{host_key}"]

  if s3_ssl_cert_path && s3_ssl_key_path
    ssl_cert_path = "/etc/nginx/certs/#{host}.crt"
    ssl_key_path = "/etc/nginx/certs/#{host}.key"

    # download key and cert from s3
    download_s3(s3_ssl_cert_path, ssl_cert_path)
    download_s3(s3_ssl_key_path, ssl_key_path)
  end

  decorator = ServerDecorator.new(
    hostname: host,
    proxy_protocol: !(ENV['DISABLE_PROXY_PROTOCOL'] == 'true'),
    ssl_cert_path: ssl_cert_path,
    ssl_key_path:  ssl_key_path,
    force_ssl: ENV['FORCE_SSL'] == 'true',
    upstream_name: ENV['UPSTREAM_NAME'],
    upstream_port: ENV['UPSTREAM_PORT']
  )
  render_template(server_conf_template_path, "/etc/nginx/conf.d/#{host}.conf", decorator: decorator)
end

if hosts.empty?
  decorator = ServerDecorator.new(
    hostname: "_",
    proxy_protocol: !(ENV['DISABLE_PROXY_PROTOCOL'] == 'true'),
    force_ssl: ENV['FORCE_SSL'] == 'true',
    upstream_name: ENV['UPSTREAM_NAME'],
    upstream_port: ENV['UPSTREAM_PORT']
  )
  render_template(server_conf_template_path, "/etc/nginx/conf.d/default.conf", decorator: decorator)
end
