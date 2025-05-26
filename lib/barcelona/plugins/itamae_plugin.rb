# Itamae plugin
# This plugin installs Itamae and apply the specified recipe on initialize
# Usage: bcn district put-plugin essa-test itamae -a recipe_url=s3://barcelona-essa-test-1573458106/itamae_recipes/recipe.tar.gz

module Barcelona
  module Plugins
    class ItamaePlugin < Base
      def on_container_instance_user_data(_instance, user_data)
        install_itamae(user_data)
        apply_itamae_recipe(user_data, attributes['recipe_url'], 'barcelona_container')
        user_data
      end

      def on_network_stack_template(_stack, template)
        bastion_lc = template["BastionLaunchConfiguration"]
        return template if bastion_lc.nil?
        return template unless attributes['recipe_url'] =~ URI::regexp

        user_data = InstanceUserData.load_or_initialize(bastion_lc["Properties"]["UserData"])

        install_itamae(user_data)
        apply_itamae_recipe(user_data, attributes['recipe_url'], 'barcelona_bastion')
        bastion_lc["Properties"]["UserData"] = user_data.build
        template
      end

      private

      def install_itamae(user_data)
        user_data.packages += %w(
          gcc-c++
          redhat-rpm-config
        )
        user_data.run_commands += <<~EOS.split("\n")
          amazon-linux-extras install ruby2.6
          yum install -y ruby-devel
          gem install itamae -v '1.10.6' -N
          gem install io-console -N
        EOS
      end

      def apply_itamae_recipe(user_data, recipe_url, role)
        archive = Pathname.new(URI.parse(recipe_url).path).basename
        user_data.add_file("/usr/local/bin/apply_itamae.sh", "root:root", "755", <<~EOS)
          #!/bin/bash
          set -ex
          # download the recipe
          mkdir /root/itamae && cd /root/itamae
          aws s3 cp #{recipe_url} .
          tar zxvf #{archive}
          # Make sudo usable without tty
          sed -i -e "s/^ *Defaults *requiretty/# Defaults requiretty/" /etc/sudoers
          # apply itamae recipe
          itamae local roles/#{role}.rb -y nodes/#{role}.yml -l info > /var/log/itamae.log
        EOS

        user_data.run_commands += [
          '/usr/local/bin/apply_itamae.sh'
        ]
      end
    end
  end
end
