# Alice

Script for creating aliases for an existing Jabber-accounts.

Developed and tested for using with [ejabberd](https://www.ejabberd.im/) server.

Named after the main character of two most famous novels by L. Carroll.

## System requirements

Script requires this Perl-modules:

* Getopt::Long
* Net::Jabber
* POSIX
* XML::Simple

## ejabberd setup for using Alice

In `listen` section one should add:

```
### External Logger
  -
    port: 8887
    ip: "127.0.0.1"
    access: all
    module: ejabberd_service
    hosts:
      "alice.somehost.somedomain":
        password: "0123456789abcdef"

```

