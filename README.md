# Digital Ocean API hook for dehydrated ACME client

By John O'Rourke for [GetConnect](https://www.getconnect.net)

This is a hook allowing [dehydrated](https://dehydrated.io/), the simple ACME/LetsEncrypt client, to create Digital Ocean DNS records for SSL Certificate verification.

Based on [https://github.com/silkeh/pdns_api.sh](https://github.com/silkeh/pdns_api.sh)

License: EUPL 1.2

DNS-based SSL certificate verification is useful for wildcard certificates.

# How To Use

1. Create a Digital Ocean token here: [https://cloud.digitalocean.com/account/api/tokens](https://cloud.digitalocean.com/account/api/tokens)

2. set it as an environment variable:

```
export DIGITALOCEAN_TOKEN=xxxxxxxxxxxxxxxxx
```

3. Run dehydrated (example)

```
dehydrated --cron --hook /path/to/this/script.sh --accept-terms --challenge dns --domain www.mywebsite.com
```

## Wildcard domains

Create a text file in the [format described here](https://github.com/dehydrated-io/dehydrated/blob/master/docs/domains_txt.md)

eg.

```
servers.mydomain.com *.servers.mydomain.com
```

Then point dehydrated at that file:

```
dehydrated --cron --hook /path/to/this/script.sh --accept-terms --challenge dns --domains-txt /path/to/your/domains.txt
```

## Testing

See [dehydrated staging options](https://github.com/dehydrated-io/dehydrated/blob/master/docs/staging.md)

# References

- [DigitalOcean API](https://docs.digitalocean.com/reference/api/digitalocean/#tag/Domain-Records/operation/domains_create_record)
- [PowerDNS version source](https://github.com/silkeh/pdns_api.sh/blob/master/pdns_api.sh)



