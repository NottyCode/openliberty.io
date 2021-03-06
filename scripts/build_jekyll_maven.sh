# This script contains the end-to-end steps for building the website with Jekyll and using Maven to package
# Exit immediately if a simple command exits with a non-zero status.
set -e

./scripts/build_gem_dependencies.sh

# Install the latest node version using nvm (Node Version Manager)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.3/install.sh | bash
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
nvm install --lts

echo "Ruby version:"
echo `ruby -v`

echo "npm version:"
echo `npm -v`

# Install Antora on the machine
npm i -g @antora/cli@2.3.3

# Guides that are ready to be published to openliberty.io
echo "Cloning repositories with name starting with guide or iguide..."
ruby ./scripts/build_clone_guides.rb

# Development environment only actions
if [ "$JEKYLL_ENV" != "production" ]; then
    echo "Not in production environment..."
    echo "Adding robots.txt"
    cp robots.txt src/main/content/robots.txt
    cp src/main/content/_includes/noindex.html src/main/content/antora_ui/src/partials/noindex.hbs

    # Development environments with draft docs/guides
    if [ "$DRAFT_GUIDES" == "true" ]; then
        echo "Clone draft guides for test environments..."
        ruby ./scripts/build_clone_guides.rb "draft-guide"    

        # Need to make sure there are draft-iguide* folders before using the find command
        # If we don't, the find command will fail because the path does not exist
        if [ $(find src/main/content/guides -type d -name "draft-iguide*" | wc -l ) != "0" ] ; then
            echo "Moving any js and css files from draft interactive guides..."
            find src/main/content/guides/draft-iguide* -d -name js -exec cp -R '{}' src/main/content/_assets \;
            find src/main/content/guides/draft-iguide* -d -name css -exec cp -R '{}' src/main/content/_assets \;
        fi
    fi
fi

# Special external link handling
pushd gems/ol-target-blank
gem build ol-target-blank.gemspec
gem install ol-target-blank-0.0.1.gem
popd

echo "Copying guide images to /img/guide"
mkdir -p src/main/content/img/guide

# Find images in draft guides and copy to img/guide/{projectid}
find src/main/content/guides/draft-guide*/assets/* | while read line; do
    imgPath=$(echo "$line" | sed -e 's/guides\/draft-guide-/img\/guide\//g' | sed 's/\/assets\/.*//g')
    mkdir -p $imgPath && cp -R $line "$_"
done

# Find images in published guides and copy to img/guide/{projectid}
find src/main/content/guides/guide*/assets/* | while read line; do
    imgPath=$(echo "$line" | sed -e 's/guides\/guide-/img\/guide\//g' | sed 's/\/assets\/.*//g')
    mkdir -p $imgPath && cp -R $line "$_"
done

# Move any js/css files from guides to the _assets folder for jekyll-assets minification.
echo "Moving any js and css files published interactive guides..."
# Assumption: There is _always_ iguide* folders
find src/main/content/guides/iguide* -d -name js -exec cp -R '{}' src/main/content/_assets \;
find src/main/content/guides/iguide* -d -name css -exec cp -R '{}' src/main/content/_assets \;

# Build and clone certifications
./scripts/build_clone_certifications.sh

# Build draft and published blogs
./scripts/build_clone_blogs.sh

# Jekyll build
echo "Building with jekyll..."
echo `jekyll -version`
mkdir -p target/jekyll-webapp

# Enable google analytics if ga is true
if [ "$ga" = true ]
  then 
    jekyll build --source src/main/content --config src/main/content/_config.yml,src/main/content/_google_analytics.yml --destination target/jekyll-webapp 
  else
    # Set the --future flag to show blogs with date timestamps in the future
    jekyll build --future --source src/main/content --destination target/jekyll-webapp 
fi

# Determine which branch of docs-javadoc repo to clone
BRANCH_NAME="prod"
if [ "$STAGING_SITE" == "true" ]; then
    echo "Cloning the staging branch of javadocs"
    BRANCH_NAME="staging"
elif [ "$DRAFT_SITE" == "true" ]; then
    echo "Cloning the draft branch of javadocs"
    BRANCH_NAME="draft"
else
    echo "Cloning the prod branch of javadocs"
fi
# Clone docs-javadoc repo
pushd src/main/content
# Remove previous installations of docs-javadoc
rm -rf docs-javadoc
git clone https://github.com/OpenLiberty/docs-javadoc.git --branch $BRANCH_NAME
popd

# Install Antora packages and build the Antora UI bundle
./scripts/build_antora_ui.sh

# Use the Antora playbook to download the docs and build the doc pages
./scripts/build_clone_antora_playbook.sh

echo "Using the Antora playbook to generate what content to display for docs"
if [ "$ga" = true ]
  then    
    # Enable google analytics in docs
    # antora --fetch --stacktrace --google-analytics-key=GTM-TKP3KJ7 src/main/content/docs/antora-playbook.yml
    
    # use local copy of antora. Once antora is upgraded to 3.0 the line below should be removed and replaced with the commented out line above
    antora/node_modules/.bin/antora --fetch --stacktrace --google-analytics-key=GTM-TKP3KJ7 src/main/content/docs/antora-playbook.yml
  else
    # antora --fetch --stacktrace src/main/content/docs/antora-playbook.yml
    
    # use local copy of antora. Once antora is upgraded to 3.0 the line below should be removed and replaced with the commented out line above
    antora/node_modules/.bin/antora --fetch --stacktrace src/main/content/docs/antora-playbook.yml
fi

# Copy the contents generated by Antora to the website folder
echo "Moving the Antora docs to the jekyll webapp"
mkdir -p target/jekyll-webapp/docs/
cp -r src/main/content/docs/build/site/. target/jekyll-webapp/

# Move the javadocs into the web app
echo "Moving javadocs to the jekyll webapp"
cp -r src/main/content/docs-javadoc/modules target/jekyll-webapp/docs

# Special handling for javadocs
./scripts/modify_javadoc.sh

python3 ./scripts/parse-feature-toc.py

# Maven packaging
# A Maven wrapper is used to set our own Maven version independent of the build environment and is specified in ./mvn/wrapper/maven-wrapper.properties
# Set the TLS Protocol to 1.2 for the maven wrapper on Java version 1.7
echo "Running maven (mvn)..."
./mvnw -B -Dhttps.protocols=TLSv1.2 package
