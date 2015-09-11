VERSION = 1.0

prefix = /usr/local
bindir = $(prefix)/bin
sharedir = $(prefix)/share
mandir = $(sharedir)/man
man1dir = $(mandir)/man1

all: webdeploy.1
	

webdeploy.1: webdeploy
	pod2man --name=WebDeploy -c"WebDeploy - Deploy files via FTP" --section=1 --release="Version $(VERSION)" $< > $@

install: all
	install webdeploy $(DESTDIR)$(bindir)
	install -m 0644 webdeploy.1 $(DESTDIR)$(man1dir)

clean:
	rm -f webdeploy.1

.PHONY: all clean
