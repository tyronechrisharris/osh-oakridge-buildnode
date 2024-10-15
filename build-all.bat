@echo off

cd web/oscar-viewer

npm install
npm run build

cd ..\..

call gradlew build -x test
