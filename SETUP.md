cd ~
git clone git@github.com:<yourusername>/ANewIdealista.git casa-watch
# or whatever the repo is named on GitHub - you can also rename in the GH UI
cd casa-watch
# create the scaffold.sh I gave you earlier, then:
chmod +x scaffold.sh && ./scaffold.sh
git add -A
git commit -m "scaffold repo structure"
git push