#!/bin/bash

LUAJIT_LIB="$LUAJIT/lib"
LUAJIT_INC="$LUAJIT/include"

ROOT=$PWD

if [ ! -d "./build" ]; then
  mkdir ./build
fi
# Cleanup before configure
echo "Cleanup"
for f in `find . -name \*.a`; do
  rm $f
done
for f in `find . -name \*.o`; do
  rm $f
done
rm -rf ./build/*
echo "Clean up finished"

# Grab nginx, nginx devel kit and nginx lua module
echo "Saving sources"
wget -q -O ./build/ngx_devel_kit.tar.gz https://github.com/simpl/ngx_devel_kit/archive/v0.2.19.tar.gz
wget -q -O ./build/nginx.tar.gz http://nginx.org/download/nginx-1.5.12.tar.gz
wget -q -O ./build/ngx_lua.tar.gz https://github.com/openresty/lua-nginx-module/archive/v0.9.10.tar.gz

for f in `find ./build -name \*.tar.gz`; do
  tar -zxf $f -C ./build
  rm $f
done

echo "Complete saving sources"

# Build all neccesery lua files into package
LD_OPT="-L/usr/local/lib"
mkdir ./build/libs
for f in `find . -name \*.lua | grep -v build`; do
  LIB_NAME=`basename $f .lua`.o
  luajit -b $f ./build/libs/$LIB_NAME
  LIB_PATH=$ROOT/build/libs/$LIB_NAME
  LD_OPT="$LD_OPT $LIB_PATH"
done

cd ./build/nginx-1.5.12
NGX_DEVEL_KIT=$PWD/../ngx_devel_kit-0.2.19
LUA_NGINX_MODULE=$PWD/../lua-nginx-module-0.9.10
CC_OPT="-I/usr/local/include -Wno-deprecated-declarations"

if [ ! -d $LUAJIT_LIB ] || [ ! -d $LUAJIT_INC ]; then
  echo "Not configure LUAJIT_LIB and LUAJIT_INC."
  exit 1
fi

./configure \
  --prefix=$PREFIX\
  --add-module=$NGX_DEVEL_KIT\
  --add-module=$LUA_NGINX_MODULE\
  --add-module=`passenger-config --nginx-addon-dir`\
  --with-cc-opt="$CC_OPT"\
  --with-ld-opt="$LD_OPT"\
  --with-pcre\
  --with-pcre-jit\
  --with-http_stub_status_module

make -j2
