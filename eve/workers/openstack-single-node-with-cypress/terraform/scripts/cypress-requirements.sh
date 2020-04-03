#!/bin/bash

set -xue -o pipefail

YUM_OPTS=(
    --assumeyes
    --setopt 'skip_missing_names_on_install=False'
)
NPM_OPTS=(
    --no-save
    --quiet
    --no-package-lock
)
RPM_PACKAGES=(
    gtk3
    nodejs
)
NODE_PACKAGES=(
    cypress@3.5.0
    cypress-cucumber-preprocessor@1.12.0
    cypress-wait-until@1.6.0
)

curl -sL https://rpm.nodesource.com/setup_10.x | sudo bash -

sudo yum install "${YUM_OPTS[@]}" "${RPM_PACKAGES[@]}"

npm install "${NPM_OPTS[@]}" "${NODE_PACKAGES[@]}"

sudo chown root:root "$HOME/.cache/Cypress/3.5.0/Cypress/chrome-sandbox"
sudo chmod 4755 "$HOME/.cache/Cypress/3.5.0/Cypress/chrome-sandbox"
