# JPE

[![Build Status](https://github.com/floswald/JPE.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/floswald/JPE.jl/actions/workflows/CI.yml?query=branch%3Amain)


## ENV vars needed

1. `JPE_DB`: location of local duckdb
2. `JPE_TOOLS_JL`: location of JPEtools.jl package on disk
3. `JPE_GOOGLE_KEY`: location of gmail/gsheets API credentials json on disk
4. `JPE_DBOX_APPS`: location of dropbox apps folder on disk
5. `JPE_DBOX_APP_SECRET`: app secret of JPE-packages dropbox [app](https://www.dropbox.com/developers/apps/info/l5g60uc0i2yn2iw)
6. `JPE_DBOX_APP_REFRESH`: refresh token to get new access for app every 30 minutes.


## setup instructions mac

### python installation

* use pyenv: `brew install pyenv`
* use pyenv-virtualenv: `brew install pyenv-virtualenv`
* set [shell options](https://github.com/pyenv/pyenv?tab=readme-ov-file#b-set-up-your-shell-environment-for-pyenv)
* install python with `env PYTHON_CONFIGURE_OPTS="--enable-framework" pyenv install 3.13.5`
* create in root of `JPE.jl` a virtual env with ` pyenv virtualenv 3.13.5 jpe-env`
* install deps with `pip install -r requirements.txt`


## julia installation

* PyCall.jl: needs to have `ENV["PYTHON"] = "/Users/florianoswald/.pyenv/shims/python"` so that it picks up the local env