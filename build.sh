ENV=$1
if [[ $# != 1 || $ENV != "dev" && $ENV != "qa" && $ENV != "prod" ]]
then
	echo "Usage: ./build.sh ENV"
	echo "ENV must be one of - dev, qa, prod"
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

if [ $ENV == "dev" ]
then
	cp -R src/dev dist/
fi

if [ $ENV != "prod" ]
then
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder-$ENV\.com/g" dist/sites-enabled/www.topcoder.com.nginx.conf
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder-$ENV\.com/g" dist/sites-enabled/apple.topcoder.com.nginx.conf
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder-$ENV\.com/g" dist/sites-enabled/app.topcoder.com.nginx.conf
else
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" dist/sites-enabled/www.topcoder.com.nginx.conf
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" dist/sites-enabled/apple.topcoder.com.nginx.conf
	perl -pi -e "s/\{\{ENV_TLD\}\}/topcoder\.com/g" dist/sites-enabled/app.topcoder.com.nginx.conf
fi

perl -pi -e "s/\{\{ENV\}\}/$ENV/g" dist/sites-enabled/www.topcoder.com.nginx.conf
perl -pi -e "s/\{\{ENV\}\}/$ENV/g" dist/sites-enabled/apple.topcoder.com.nginx.conf
perl -pi -e "s/\{\{ENV\}\}/$ENV/g" dist/sites-enabled/app.topcoder.com.nginx.conf

#if [ $ENV == "dev" ]
#then
#	perl -pi -e "s/0KG93JqIgDpdGzlUbpGzQSeD39L1rc/dev0KG93JqIgDpdGzlUbpGzQSeD39L1rc/g" dist/sites-enabled/www.topcoder.com.nginx.conf
#else qa
#	perl -pi -e "s/0KG93JqIgDpdGzlUbpGzQSeD39L1rc/qA0KG93JqIgDpdGzlUbpGzQSeD39L1rc/g" dist/sites-enabled/www.topcoder.com.nginx.conf
#fi

docker build -t appiriodevops/nginx-supply:dev .