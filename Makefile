DATE := $(shell date +"%Y-%m-%d")
FILE := $(DATE)-$(TOPIC)
SHORT_FILE := $(DATE)-$(TOPIC)
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
	test ! -e _posts/$(FILE).markdown || { echo "error: _posts/$(FILE).markdown already exists"; exit 1; }
	cp templates/_post.markdown _posts/$(FILE).markdown
	nvim _posts/$(FILE).markdown

gen.short:
	test -n "$(TOPIC)" || { echo "usage: make gen.short TOPIC=slug"; exit 1; }
	test ! -e _shorts/$(SHORT_FILE).markdown || { echo "error: _shorts/$(SHORT_FILE).markdown already exists"; exit 1; }
	cp templates/_short.markdown _shorts/$(SHORT_FILE).markdown
	sed -i '' -e "s/^date:.*/date: $$(date +'%Y-%m-%d %H:%M')/" _shorts/$(SHORT_FILE).markdown
	nvim _shorts/$(SHORT_FILE).markdown

deploy:
	gh workflow run jekyll-github-pages.yml --ref main
	@echo "dispatched; watch with: gh run watch"

deploy.status:
	gh run list --workflow jekyll-github-pages.yml --limit 5

clear.cache:
	rm _cache/**

remote.setup:
	gh secret set ACCESS_TOKEN -b $(GITHUB_ACCESS_TOKEN)
