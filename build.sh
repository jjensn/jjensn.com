rm -rf _site
jekyll build
#chown -R www-data:www-data /home/jj/jjensn.com/_site
sudo chown -R "$USER":www-data /home/jj/jjensn.com/_site
sudo chmod -R 0755 /home/jj/jjensn.com/_site
