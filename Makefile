
all: webdeploy.1
	

webdeploy.1: webdeploy.pl
	pod2man --name=WebDeploy -c"WebDeploy - Deploy files via FTP" --section=1 --release="Version 1.0" $< > $@

clean:
	rm -r webdeploy.1

.PHONY: all clean
