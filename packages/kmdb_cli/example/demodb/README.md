# Demo database

```sh
dart run ../../bin/kmdb.dart demodb --read tags.data
dart run ../../bin/kmdb.dart demodb --read airports.data
```

```
dart run ../../bin/kmdb.dart demodb collections
dart run ../../bin/kmdb.dart demodb count airports
```

```
dart run ../../bin/kmdb.dart demodb stats
dart run ../../bin/kmdb.dart demodb info
dart run ../../bin/kmdb.dart demodb verify
dart run ../../bin/kmdb.dart demodb compact
```

To delete the database, just run `rm -rf demodb`

## Data prep

You might want to try some data loading and there are some small helper scripts:

- `csv2json.py`: converts a CSV file (with a header row) to JSON.
- `csv2ndjson`: converts a CSV file (with headers) to
  [NDJSON](https://jsonltools.com/what-is-ndjson).

## Sources

- [Airport Codes](https://datahub.io/core/airport-codes)
- [Weather stations](https://data.un.org/Data.aspx?d=CLINO&f=ElementCode%3A15)
- [ISO 3166-1 (2-digit country-codes)](https://datahub.io/core/country-list)
