---
category: Ansible
path: '/_posts'
title: 'Tower + SAML Authentication'
type: 'DEVOPS'

layout: null
---

I'm just going to throw it out there -- SAML is complicated. And for the cost per managed host, Ansible Tower with SAML sucks even more. Putting the two of them together made for a frustrating day of whack-a-mole. 

Find my solution below to properly implement G-Suite SAML authentication with Ansible Tower.

## STRANGE BEHAVIOR IN TOWER SAML LIBRARY

At the time of writing this, Tower's SAML library does something strange when it comes to validating a SAML response when terminating the SSL connection on an ELB.

```That means configuring nginx on the Tower server to use port 
443/HTTP instead of the default 443/HTTPS.```

If you're interested, you can see why [here](https://github.com/ansible/awx/issues/1016#issuecomment-397776683). 

ELI5: OneLogin's SAML library uses the listening port of the webserver instead of using the user-defined Ansible Tower URL. You can fix it by fighting with the headers like the original author mentions, or simply disable SSL and serve HTTP over 443.

## CONFIGURE TOWER

#### In the SAML Enabled Identity Providers field (admin settings) paste the following:
```{
 "idp": {
  "attr_username": "name_id",
  "entity_id": "https://accounts.google.com/o/saml2?idpid=XXXXX",
  "attr_user_permanent_id": "name_id",
  "url": "https://accounts.google.com/o/saml2/idp?idpid=XXXXX",
  "attr_email": "name_id",
  "x509cert": "THE_X509_CERT_FROM_GOOGLE_HERE_MAKE_SURE_YOU_ONE_LINE_IT"
 }
}```

I had a lot of problems with this; nothing online was really clear about what SAML attributes I needed to tell Tower about. Since Google uses the e-mail address as the unique ID, I wanted to also use the e-mail as the username for Tower. In retrospect it seems simple, but without the "attr_email" setting, users are given a username of a hash instead of the email. Don't forget to [one-line the certificate](https://www.samltool.com/format_x509cert.php).

## PREVENT GLOBAL LOGINS

If you want everyone in your G-Suite account to be able to authenticate to Tower, you're all done.

If you'd rather create the account in Tower first (to set the user permissions) and use Google to handle the authentication, then you'll need to make a small change to Ansible's config file on the Tower host.

1. Open **`/etc/tower/settings.py`**

2. Add the following line at the bottom: **`SOCIAL_AUTH_USER_FIELDS = []`**

The Tower docs crack me up. One paragraph will reference the settings in the admin panel, then the next paragraph talks about the settings.py file without ever mentioning it. I kept pasting this into the fields into the Tower SAML settings page and it (not surprisingly) kept complaining.

I hope this made you're day a little easier.