DATE := $(shell date +"%Y-%m-%d")
FILE := $(DATE)-$(TOPIC)
GITHUB_ACCESS_TOKEN := $(shell grep -oE '^BLOG_GITHUB_ACCESS_TOKEN=(.*)' ~/.gittokens | cut -d'=' -f2)

serve:
	LANG="en_US.UTF-8" \
	     LANGUAGE="en_US.UTF-8" \
	     LC_CTYPE="en_US.UTF-8" \
	     LC_MONETARY="en_US.UTF-8" \
	     LC_NUMERIC="en_US.UTF-8" \
	     LC_ALL="en_US.UTF-8" ./bin/jekyll serve --livereload

gen.file:
	echo $(FILE)
	touch _posts/$(FILE).markdown

clear.cache:
	rm _cache/**

remote.setup:
	gh secret set ACCESS_TOKEN -b $(GITHUB_ACCESS_TOKEN)
