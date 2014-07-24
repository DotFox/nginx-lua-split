#!/bin/bash

if [ $1 == '--help' ]; then
  echo "Build nginx with lua-nginx and injected A/B engine"
  echo ""
  echo "Run script with:"
  echo ""
  echo "  PREFIX - where nginx will be installed (full path)."
  echo "  LUAJIT - where luajit-2.1 will be installed (full path)."
  echo "  NGINXV - nginx version (tested 1.7.2 and 1.5.12). Default - 1.5.12."
  exit 0
fi

NGINX_VERSION=1.5.12

if [ "$NGINXV" == "1.5.12" || "$NGINXV" == "1.7.2" ]; then
  NGINX_VERSION=$NGINXV
fi

if [ ! -d $LUAJIT ]; then
  echo "Luajit must be installed in specified directory."
  exit 1
fi

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
wget -q -O ./build/nginx.tar.gz http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz
wget -q -O ./build/ngx_lua.tar.gz https://github.com/openresty/lua-nginx-module/archive/v0.9.10.tar.gz
git clone http://luajit.org/git/luajit-2.0.git ./build/luajit_src

for f in `find ./build -name \*.tar.gz`; do
  tar -zxf $f -C ./build
  rm $f
done

echo "Complete saving sources"

echo "Build luajit"
cd build/luajit_src
git checkout v2.1
make PREFIX=$LUAJIT
make install PREFIX=$LUAJIT
ln -sf $LUAJIT/bin/luajit-2.1.0-alpha $LUAJIT/bin/luajit
LUAJIT_BIN=$LUAJIT/bin/luajit
LUAJIT_LIB=$LUAJIT/lib
LUAJIT_INC=$LUAJIT/include/luajit-2.1
cd $ROOT
echo "luajit configured"

# Build all neccesery lua files into package
LD_OPT="-L/usr/local/lib"
mkdir ./build/libs
for f in `find . -name \*.lua | grep -v build`; do
  LIB_NAME=`basename $f .lua`.o
  $LUAJIT_BIN -b $f ./build/libs/$LIB_NAME
  LIB_PATH=$ROOT/build/libs/$LIB_NAME
  LD_OPT="$LD_OPT $LIB_PATH"
done
LD_OPT="$LD_OPT -Wl,-rpath,$LUAJIT_LIB"

cd ./build/nginx-$NGINX_VERSION
NGX_DEVEL_KIT=$PWD/../ngx_devel_kit-0.2.19
LUA_NGINX_MODULE=$PWD/../lua-nginx-module-0.9.10
CC_OPT="-I/usr/local/include -Wno-deprecated-declarations"

if [ ! -d $LUAJIT_LIB ] || [ ! -d $LUAJIT_INC ]; then
  echo "Not configure LUAJIT_LIB and LUAJIT_INC."
  exit 1
fi

PASSENGER_ADDON_DIR=`passenger-config --nginx-addon-dir`
if [ ! -d $PASSENGER_ADDON_DIR ]; then
  PASSENGER_ADDON_DIR=`passenger --includedir`/nginx
fi

LUAJIT_LIB=$LUAJIT_LIB LUAJIT_INC=$LUAJIT_INC ./configure \
  --prefix=$PREFIX\
  --add-module=$NGX_DEVEL_KIT\
  --add-module=$LUA_NGINX_MODULE\
  --add-module=$PASSENGER_ADDON_DIR\
  --with-cc-opt="$CC_OPT"\
  --with-ld-opt="$LD_OPT"\
  --with-pcre\
  --with-pcre-jit\
  --with-http_gzip_static_module\
  --with-http_stub_status_module

make -j2
make install
