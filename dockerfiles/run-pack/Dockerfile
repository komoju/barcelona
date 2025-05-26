FROM alpine

ADD . /.go/src/app

RUN apk add --no-cache go curl git gcc libc-dev \
  && cd /.go/src/app \
  && mkdir /barcelona \
  && go build -o /barcelona/barcelona-run --ldflags '-linkmode external -extldflags "-static"' \
  && rm -rf /.go \
  && apk del --purge go curl git gcc libc-dev

VOLUME ["/barcelona"]

CMD ["/bin/true"]
