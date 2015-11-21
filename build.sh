#!/bin/bash -x
if [ "$ENV" != "dev" ] && [ "$ENV" != "qa" ]  && [ "$ENV"!= "prod" ] && [ "$ENV" != "local" ] ; then
	echo "Usage: ./build.sh and environment should be set on startup"
	echo "ENV must be one of - dev, qa, prod or local"
	exit
fi

rm -rf dist
mkdir dist
mkdir dist/sites-enabled
mkdir dist/includes

# copy know conf folders
cp src/sites-enabled/*conf dist/sites-enabled/
cp src/includes/*conf dist/includes/
cp src/*conf dist/

if [ "$ENV" == "dev" ] ; then
	cp -R src/dev dist/
fi

if [ "$ENV" == "local" ] ; then
	cp -R src/local /data/nginx
fi

if [ "$ENV" != "prod" ] ; then
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder-$ENV\.com/g" dist/sites-enabled/*conf
else
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" dist/sites-enabled/*conf
fi

perl -pi -e "s/\{\{ENV\}\}/$ENV/g" dist/sites-enabled/*conf