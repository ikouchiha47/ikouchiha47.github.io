#!/bin/bash
#
# Run jekyll build and push _site to gh-pages.
#
set -e

echo "🚀 Starting deployment action"

REMOTE_REPO="https://${GITHUB_ACTOR}:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
CLONE_DEST="src/blog"

mkdir =p "${CLONE_DEST}"

git clone "${REMOTE_REPO}" "${CLONE_REPO}" 
cd "${REMOTE_REPO}"

echo "⚡️ Installing project dependencies..."
bundle install --binstubs

echo "🏋️ Building website..."
JEKYLL_ENV=production ./bin/jekyll build
echo "Jekyll build done"

mv _site ../

echo "☁️  Publishing website"
cd ../_site

# initializing git
git init
git config user.name "${GITHUB_ACTOR}"
git config user.email "${GITHUB_ACTOR}@users.noreply.github.com"
git checkout -b master
git add .

git commit -m "Github Actions: Publishing Static site - $(date)"
echo "Build branch ready to go. Pushing to Github..."

git push --force $REMOTE_REPO master:gh-pages

# cleanup
rm -fr .git
cd ..
rm -rf src

echo "🎉 New version deployed 🎊"
