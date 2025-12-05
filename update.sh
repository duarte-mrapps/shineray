#!/bin/bash

set -e

# CONFIG
BACKUP_BRANCH="template-cardealer"
TEMPLATE_REPO="https://github.com/MobiAppsByMobiGestor/appdaloja.git"

log() {
  echo -e "\033[1;34m➔ $1\033[0m"
}

# Valida se é um repositório Git
log "Validating Git repository..."
if [ ! -d .git ]; then
  log "This directory is not a Git repository!"
  exit 1
fi

# Garante que estamos na main
git checkout main
git pull origin main

# Verifica se existem alterações não commitadas na main
if ! git diff-index --quiet HEAD --; then
  log "There are uncommitted changes on main. Please commit or stash them before running this script."
  exit 1
fi

# Deleta branch de backup se já existir (local e remoto)
if git show-ref --verify --quiet refs/heads/$BACKUP_BRANCH; then
  log "Local branch $BACKUP_BRANCH exists. Deleting..."
  git branch -D $BACKUP_BRANCH
fi

if git ls-remote --exit-code --heads origin $BACKUP_BRANCH &> /dev/null; then
  log "Remote branch $BACKUP_BRANCH exists. Deleting..."
  git push origin --delete $BACKUP_BRANCH
fi

# Cria branch de backup
log "Creating backup branch $BACKUP_BRANCH..."
git checkout -b $BACKUP_BRANCH
git push -u origin $BACKUP_BRANCH
git checkout main

# Extrai variáveis
log "Extracting variables..."
APPLICATION_ID=$(grep applicationId android/app/build.gradle | head -n 1 | cut -d '"' -f2)
IOS_PROJECT_PATH=$(find ios -name "*.xcodeproj" | head -n 1)
PBXPROJ_PATH="$IOS_PROJECT_PATH/project.pbxproj"

BUNDLE_ID=$(grep "PRODUCT_BUNDLE_IDENTIFIER" $PBXPROJ_PATH | awk -F'= ' '{print $2}' | tr -d ' ;' | grep '^com\..*\.ios.*$' | head -n 1)
[ -z "$BUNDLE_ID" ] && { log "Invalid bundle ID"; exit 1; }

APP_NAME_ANDROID=$(grep 'name="app_name"' android/app/src/main/res/values/strings.xml | sed -E 's/.*>(.*)<.*/\1/')
APP_NAME_IOS=$(grep INFOPLIST_KEY_CFBundleDisplayName "$PBXPROJ_PATH" | grep -v OneSignalNotificationServiceExtension | head -n 1 | cut -d '=' -f2 | cut -d ';' -f1 | sed 's/"//g' | xargs)
APP_NAME=${APP_NAME_IOS:-$APP_NAME_ANDROID}

SESSION_FILE="src/libs/session.js"
ACCOUNT_ID=$(grep "ACCOUNT_ID" $SESSION_FILE | head -n 1 | sed -E "s/.*ACCOUNT_ID: '([^']+)'.*/\1/")
ONESIGNAL_APP_ID=$(grep "ONESIGNAL_APP_ID" $SESSION_FILE | head -n 1 | sed -E "s/.*ONESIGNAL_APP_ID: '([^']+)'.*/\1/")

OLD_STORYBOARD=$(find ios -name "LaunchScreen.storyboard" | grep -v appdaloja | head -n 1)
RED=$(grep -o 'red="[^"]*"' "$OLD_STORYBOARD" | head -n1 | cut -d'"' -f2)
GREEN=$(grep -o 'green="[^"]*"' "$OLD_STORYBOARD" | head -n1 | cut -d'"' -f2)
BLUE=$(grep -o 'blue="[^"]*"' "$OLD_STORYBOARD" | head -n1 | cut -d'"' -f2)

CARDEALER_PBXPROJ="ios/cardealer.xcodeproj/project.pbxproj"
APPDALOJA_PBXPROJ="ios/appdaloja.xcodeproj/project.pbxproj"
MARKETING_VERSION=$(grep -v OneSignalNotificationServiceExtension "$CARDEALER_PBXPROJ" | grep MARKETING_VERSION | head -n 1 | awk '{print $3}' | tr -d ';')
CURRENT_PROJECT_VERSION=$(grep -v OneSignalNotificationServiceExtension "$CARDEALER_PBXPROJ" | grep CURRENT_PROJECT_VERSION | head -n 1 | awk '{print $3}' | tr -d ';')

VERSION_NAME=$(grep versionName android/app/build.gradle | head -n 1 | cut -d '"' -f2)
VERSION_CODE=$(grep versionCode android/app/build.gradle | head -n 1 | awk '{print $2}')

# Keystore configs
KEYSTORE_PATH="android/app/cardealer.keystore"
MYAPP_RELEASE_STORE_FILE="cardealer.keystore"
MYAPP_RELEASE_KEY_ALIAS="cardealer-alias"
MYAPP_RELEASE_STORE_PASSWORD="cardealer"
MYAPP_RELEASE_KEY_PASSWORD="cardealer"

# Backup dos assets
log "Backing up assets..."
TMP_BACKUP=$(mktemp -d)
mkdir -p $TMP_BACKUP/res
cp -R android/app/src/main/res/* $TMP_BACKUP/res/
mkdir -p $TMP_BACKUP/xcassets
cp -R ios/cardealer/Images.xcassets/* $TMP_BACKUP/xcassets/
cp ios/GoogleService-Info.plist $TMP_BACKUP/ || true
cp android/app/google-services.json $TMP_BACKUP/ || true
[ -d prints ] && cp -R prints $TMP_BACKUP/ || true
cp $KEYSTORE_PATH $TMP_BACKUP/ || true

# Limpa projeto
log "Cleaning project on main branch..."
find . -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} \;

# Clona template
log "Cloning template repository..."
WORK_DIR=$(mktemp -d)
git clone $TEMPLATE_REPO $WORK_DIR
rm -rf $WORK_DIR/.git

# Substitui placeholders
cd $WORK_DIR
for placeholder in APPLICATION_ID BUNDLE_ID ACCOUNT_ID ONESIGNAL_APP_ID APP_NAME RED GREEN BLUE
  do
    value=$(eval echo \$$placeholder)
    grep -rl "{{${placeholder}}}" . | while read file; do
      sed -i.bak "s/{{${placeholder}}}/${value}/g" "$file" && rm "$file.bak"
    done
  done

# Atualiza versões no pbxproj
test -f "$APPDALOJA_PBXPROJ" && {
  sed -i.bak "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $MARKETING_VERSION;/" "$APPDALOJA_PBXPROJ"
  sed -i.bak "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $CURRENT_PROJECT_VERSION;/" "$APPDALOJA_PBXPROJ"
  rm "$APPDALOJA_PBXPROJ.bak"
}

# Atualiza versões no build.gradle
BUILD_GRADLE="android/app/build.gradle"
sed -i.bak "s/versionCode .*/versionCode $VERSION_CODE/" "$BUILD_GRADLE"
sed -i.bak "s/versionName \".*\"/versionName \"$VERSION_NAME\"/" "$BUILD_GRADLE"
rm "$BUILD_GRADLE.bak"

# Atualiza gradle.properties com keystore
GRADLE_PROPERTIES="android/gradle.properties"
sed -i.bak '/^MYAPP_RELEASE_/d' "$GRADLE_PROPERTIES"
rm "$GRADLE_PROPERTIES.bak"
{
  echo "MYAPP_RELEASE_STORE_FILE=$MYAPP_RELEASE_STORE_FILE"
  echo "MYAPP_RELEASE_KEY_ALIAS=$MYAPP_RELEASE_KEY_ALIAS"
  echo "MYAPP_RELEASE_STORE_PASSWORD=$MYAPP_RELEASE_STORE_PASSWORD"
  echo "MYAPP_RELEASE_KEY_PASSWORD=$MYAPP_RELEASE_KEY_PASSWORD"
} >> "$GRADLE_PROPERTIES"

# Restaura assets
log "Restoring assets into template..."
mkdir -p android/app/src/main/res
cp -R $TMP_BACKUP/res/* android/app/src/main/res/
mkdir -p ios/appdaloja/Images.xcassets
cp -R $TMP_BACKUP/xcassets/* ios/appdaloja/Images.xcassets/
cp $TMP_BACKUP/GoogleService-Info.plist ios/ || true
cp $TMP_BACKUP/google-services.json android/app/ || true
cp $TMP_BACKUP/cardealer.keystore android/app/ || true
cp -R $TMP_BACKUP/prints . 2>/dev/null || true

# ────────────────────────────────────────────────────────────────────────────────
# 6.5 Tratamento de imagens duplicadas (WEBP vs PNG)
# ────────────────────────────────────────────────────────────────────────────────
log "Removing duplicated PNGs when WEBP equivalents exist..."
for dir in $TMP_BACKUP/res/mipmap-*; do
  [ -d "$dir" ] || continue
  for webp_file in "$dir"/*.webp; do
    [ -f "$webp_file" ] || continue
    filename=$(basename "$webp_file" .webp)
    target_png="android/app/src/main/res/$(basename "$dir")/$filename.png"
    if [ -f "$target_png" ]; then
      log "Removing duplicated PNG: $target_png"
      rm "$target_png"
    fi
  done
done



# Atualiza ic_launcher_background
OLD_COLORS_XML="$TMP_BACKUP/res/values/colors.xml"
NEW_BG_XML="android/app/src/main/res/values/ic_launcher_background.xml"
NEW_COLORS_XML="android/app/src/main/res/values/colors.xml"
if [ -f "$OLD_COLORS_XML" ]; then
  LAUNCHER_COLOR=$(grep '<color name="ic_launcher_background"' "$OLD_COLORS_XML" | sed -E 's/.*>(.*)<.*/\1/')
  if [ -n "$LAUNCHER_COLOR" ]; then
    log "Updating ic_launcher_background color to: $LAUNCHER_COLOR"
    sed -i.bak "s|<color name=\"ic_launcher_background\">.*</color>|<color name=\"ic_launcher_background\">$LAUNCHER_COLOR</color>|" "$NEW_BG_XML" && rm "$NEW_BG_XML.bak"
    sed -i.bak '/<color name="ic_launcher_background">.*<\/color>/d' "$NEW_COLORS_XML" && rm "$NEW_COLORS_XML.bak"
  fi
fi

cd -

log "Copying updated template to main branch..."
cp -a $WORK_DIR/. .

git add .
git commit -m "chore(template): update project using latest template version and preserve customer configuration"
git push origin main

log "Installing dependencies..."
yarn
cd ios && pod install && cd ..

log "Template applied successfully! Main branch is now updated."
log "Backup of previous version is stored in branch $BACKUP_BRANCH."
