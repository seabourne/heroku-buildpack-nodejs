build_failed() {
  head "Build failed"
  echo ""
  cat $warnings | indent
  info "We're sorry this build is failing! If you can't find the issue in application code,"
  info "please submit a ticket so we can help: https://help.heroku.com/"
  info "You can also try reverting to our legacy Node.js buildpack:"
  info "heroku config:set BUILDPACK_URL=https://github.com/heroku/heroku-buildpack-nodejs#v63"
  info ""
  info "Love,"
  info "Heroku"
}

build_succeeded() {
  head "Build succeeded!"
  echo ""
  (npm ls --depth=0 || true) 2>/dev/null | indent
  cat $warnings | indent
}

get_start_method() {
  local build_dir=$1
  if test -f $build_dir/Procfile; then
    echo "Procfile"
  elif [[ $(read_json "$build_dir/package.json" ".scripts.start") != "" ]]; then
    echo "npm start"
  elif test -f $build_dir/server.js; then
    echo "server.js"
  else
    echo ""
  fi
}

get_modules_source() {
  local build_dir=$1
  if test -d $build_dir/node_modules; then
    echo "prebuilt"
  elif test -f $build_dir/npm-shrinkwrap.json; then
    echo "npm-shrinkwrap.json"
  elif test -f $build_dir/package.json; then
    echo "package.json"
  else
    echo ""
  fi
}

get_modules_cached() {
  local cache_dir=$1
  if test -d $cache_dir/node/node_modules; then
    echo "true"
  else
    echo "false"
  fi
}

show_current_state() {
  echo ""
  info "Node engine:         ${node_engine:-unspecified}"
  info "Npm engine:          ${npm_engine:-unspecified}"
  info "Start mechanism:     ${start_method:-none}"
  info "node_modules source: ${modules_source:-none}"
  info "node_modules cached: $modules_cached"

  echo ""

  printenv | grep ^NPM_CONFIG_ | indent
  info "NODE_MODULES_CACHE=$NODE_MODULES_CACHE"
}

install_node() {
  # Resolve non-specific node versions using semver.herokuapp.com
  if ! [[ "$node_engine" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    info "Resolving node version ${node_engine:-(latest stable)} via semver.io..."
    node_engine=$(curl --silent --get --data-urlencode "range=${node_engine}" https://semver.herokuapp.com/node/resolve)
  fi

  # Download node from Heroku's S3 mirror of nodejs.org/dist
  info "Downloading and installing node $node_engine..."
  node_url="http://s3pository.heroku.com/node/v$node_engine/node-v$node_engine-linux-x64.tar.gz"
  curl $node_url -s -o - | tar xzf - -C /tmp

  # Move node (and npm) into .heroku/node and make them executable
  mv /tmp/node-v$node_engine-linux-x64/* $heroku_dir/node
  chmod +x $heroku_dir/node/bin/*
  PATH=$heroku_dir/node/bin:$PATH
}

install_npm() {
  # Optionally bootstrap a different npm version
  if [ "$npm_engine" != "" ]; then
    if ! [[ "$npm_engine" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      info "Resolving npm version ${npm_engine} via semver.io..."
      npm_engine=$(curl --silent --get --data-urlencode "range=${npm_engine}" https://semver.herokuapp.com/npm/resolve)
    fi
    if [[ `npm --version` == "$npm_engine" ]]; then
      info "npm `npm --version` already installed with node"
    else
      info "Downloading and installing npm $npm_engine (replacing version `npm --version`)..."
      npm install --quiet -g npm@$npm_engine 2>&1 >/dev/null | indent
    fi
    warn_old_npm `npm --version`
  fi
}

get_cache_status() {
  # Did we bust the cache?
  if ! $modules_cached; then
    echo "No cache available"
  elif ! $NODE_MODULES_CACHE; then
    echo "Cache disabled with NODE_MODULES_CACHE"
  elif [ "$node_previous" != "" ] && [ "$node_engine" != "$node_previous" ]; then
    echo "Node version changed ($node_previous => $node_engine); invalidating cache"
  elif [ "$npm_previous" != "" ] && [ "$npm_engine" != "$npm_previous" ]; then
    echo "Npm version changed ($npm_previous => $npm_engine); invalidating cache"
  else
    echo "valid"
  fi
}

ensure_procfile() {
  local start_method=$1
  local build_dir=$2
  if [ "$start_method" == "Procfile" ]; then
    info "Found Procfile"
  elif test -f $build_dir/Procfile; then
    info "Procfile created during build"
  elif [ "$start_method" == "npm start" ]; then
    info "No Procfile; Adding 'web: npm start' to new Procfile"
    echo "web: npm start" > $build_dir/Procfile
  elif [ "$start_method" == "server.js" ]; then
    info "No Procfile; Adding 'web: node server.js' to new Procfile"
    echo "web: node server.js" > $build_dir/Procfile
  fi
}

write_profile() {
  info "Creating runtime environment"
  mkdir -p $build_dir/.profile.d
  echo "export PATH=\"\$HOME/.heroku/node/bin:\$HOME/bin:\$HOME/node_modules/.bin:\$PATH\"" > $build_dir/.profile.d/nodejs.sh
  echo "export NODE_HOME=\"\$HOME/.heroku/node\"" >> $build_dir/.profile.d/nodejs.sh
}

write_export() {
  info "Exporting binary paths"
  echo "export PATH=\"$build_dir/.heroku/node/bin:$build_dir/node_modules/.bin:\$PATH\"" > $bp_dir/export
  echo "export NODE_HOME=\"$build_dir/.heroku/node\"" >> $bp_dir/export
}

clean_npm() {
  info "Cleaning npm artifacts"
  rm -rf "$build_dir/.node-gyp"
  rm -rf "$build_dir/.npm"
}

clean_cache() {
  info "Cleaning previous cache"
  rm -rf "$cache_dir/node_modules" # (for apps still on the older caching strategy)
  rm -rf "$cache_dir/node"
}

create_cache() {
  info "Caching results for future builds"
  mkdir -p $cache_dir/node

  echo $node_engine > $cache_dir/node/node-version
  echo $npm_engine > $cache_dir/node/npm-version

  if test -d $build_dir/node_modules; then
    cp -r $build_dir/node_modules $cache_dir/node
  fi
}
