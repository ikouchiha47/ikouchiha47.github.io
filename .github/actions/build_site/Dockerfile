FROM ruby:3.2.2-slim

ENV BUNDLER_VERSION 2.4.10

WORKDIR /app

RUN apt-get update && \
	    apt-get install --no-install-recommends -y \
			bats \
			build-essential \
			ca-certificates \
			curl \
			libffi6 \
			make \
			shellcheck \
			libffi6 \
			git-all \
			&& gem install bundler:2.4.10 \
			&& bundle config --global silence_root_warning 1

COPY entrypoint.sh .

ENTRYPOINT ["sh", "/entrypoint.sh"]
