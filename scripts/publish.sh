#!/bin/bash
#
# Build locally and publish to gh-pages. Fucking open source and compatibilty
#
set -e

echo "Cleanup old _site"
BACKUP_FILE="site_$(date +%s).tar.gz"

if [[ -d "_site" ]]; then
  echo "Backup old _site"
  mkdir -p _site
  tar -cvzpf "${BACKUP_FILE}" _site
  rm -rf _site
fi

echo "⚡️ Installing project dependencies..."
cd blog/
bundle install --binstubs


echo "🏋️ Building website..."
JEKYLL_ENV=production ./bin/jekyll build
mv _site ../ && cd ../_site


echo "☁️  Publishing website"
git init
git checkout -b gh-pages
git remote add origin git@github.com:ikouchiha47/ikouchiha47.github.io.git

git add .
git commit -m "Github Actions: Publishing Static site - $(date)"

echo "Build branch ready to go. Pushing to Github..."
echo "git push origin -f gh-pages:gh-pages"
git push origin -f gh-pages:gh-pages

echo "🎉 New version deployed 🎊"

