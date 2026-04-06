# Demo database

Provides a walk-through of creating and interacting with a `kmdb` database.

You can create an empty database using the `init` command. In the call below,
`demodb` provides the location of the database. In this case, a directory
(database) named `demodb` will be created in the current directory.

```sh
dart run ../../bin/kmdb.dart demodb init
```

_Note that a database will also be created when you call `put` to insert data._

Let's create a new document in the `notes` collection:

```sh
dart run ../../bin/kmdb.dart demodb put notes --value '{"title": "New Note"}'
```

We can check to make sure that we have 1 document in the `notes` collection:

```sh
dart run ../../bin/kmdb.dart demodb count notes
```

The `scan` command returns all documents in the selected collection (e.g.
`notes`):

```sh
dart run ../../bin/kmdb.dart demodb scan notes
```

Scripts allow you to run multiple commands (`put`, `delete` etc) - the
[`tags.data`](tags.data) script adds 2 new documents to the `categories`
collection:

```sh
dart run ../../bin/kmdb.dart demodb --read tags.data

```

You can also load documents from a JSON file - this next call creates a
collection named `weather_stations` and adds details regarding a bunch of
weather stations around the world:

```sh
dart run ../../bin/kmdb.dart demodb put weather_stations --file weather_stations.json
```

How many weather stations do we have?

```sh
dart run ../../bin/kmdb.dart demodb count weather_stations
```

Let's check which collections we now have (we should have `notes`, `categories`
and `weather_stations`):

```sh
dart run ../../bin/kmdb.dart demodb collections
```

kmdb also supports loading from an NDJSON file - let's add in some country
codes:

```sh
dart run ../../bin/kmdb.dart demodb put country_codes --file iso_3166_1.ndjson

dart run ../../bin/kmdb.dart demodb count country_codes
```

We can also load via stdin:

```sh
cat elements.ndjson| dart run ../../bin/kmdb.dart demodb put elements
dart run ../../bin/kmdb.dart demodb count elements
```

## Query

```sh
dart run ../../bin/kmdb.dart demodb scan weather_stations --filter '{"field":"Station Name","op":"eq","value":"MAWSON"}'
```

```sh
dart run ../../bin/kmdb.dart demodb scan weather_stations --filter '{"field":"Station Name","op":"eq","value":"MAWSON"}' --mode table

dart run ../../bin/kmdb.dart demodb scan weather_stations --filter '{"field":"Station Name","op":"eq","value":"MAWSON"}' --mode csv
```

You can use `jq` to manipulate the default JSON-based output:

```sh
dart run ../../bin/kmdb.dart demodb scan weather_stations --filter '{"field":"Station Name","op":"eq","value":"MAWSON"}' | jq '.[] | {"Country or Territory", "WMO Station Number", "Period"}'
```

But using `--select` and the table mode will give you some nicely formatted
output:

```sh
dart run ../../bin/kmdb.dart demodb scan elements --filter '{"field":"Name","op":"startsWith","value":"H"}' --select Name,Symbol,Atomic_Number --mode table
```

## Export/Import

Export lets you export a collection to NDJSON format:

```sh
dart run ../../bin/kmdb.dart demodb export elements --output elements.export
```

## Backups

Let's create a backup:

```sh
dart run ../../bin/kmdb.dart demodb dump --output demodb.dump
```

We can then restore the data to a new copy of the database:

```sh
dart run ../../bin/kmdb.dart demodb_2 restore --input demodb.dump
dart run ../../bin/kmdb.dart demodb_2 collections
```

## Synchronising

```sh
mkdir -p remote_mount/demodb_sync
```

```sh
dart run ../../bin/kmdb.dart demodb remote add origin --path remote_mount/demodb_sync
```

```sh
dart run ../../bin/kmdb.dart demodb remote list
```

```sh
dart run ../../bin/kmdb.dart demodb remote remove origin
dart run ../../bin/kmdb.dart demodb remote add origin --path $PWD/remote_mount/demodb_sync
dart run ../../bin/kmdb.dart demodb remote list
```

```sh
dart run ../../bin/kmdb.dart demodb sync
```

```sh
dart run ../../bin/kmdb.dart demodb_2 scan notes
```

```sh
dart run ../../bin/kmdb.dart demodb scan notes
dart run ../../bin/kmdb.dart demodb put notes --value '{"title": "Very important note"}'
dart run ../../bin/kmdb.dart demodb sync
```

```sh
dart run ../../bin/kmdb.dart demodb_2 remote add origin --path $PWD/remote_mount/demodb_sync
dart run ../../bin/kmdb.dart demodb_2 remote list
```

```sh
dart run ../../bin/kmdb.dart demodb_2 sync
dart run ../../bin/kmdb.dart demodb_2 scan notes
```

```sh
dart run ../../bin/kmdb.dart demodb_3 init
dart run ../../bin/kmdb.dart demodb_3 remote add origin --path $PWD/remote_mount/demodb_sync
dart run ../../bin/kmdb.dart demodb_3 pull --collection notes
dart run ../../bin/kmdb.dart demodb_3 scan notes
```

We can also `init` a new database and sync across all of the shared collections:

```sh
dart run ../../bin/kmdb.dart demodb_4 init
dart run ../../bin/kmdb.dart demodb_4 remote add origin --path $PWD/remote_mount/demodb_sync
dart run ../../bin/kmdb.dart demodb_4 sync
dart run ../../bin/kmdb.dart demodb_4 collections
dart run ../../bin/kmdb.dart demodb_4 scan notes
dart run ../../bin/kmdb.dart demodb_4 put notes --value '{"title": "note to self"}'
dart run ../../bin/kmdb.dart demodb_4 sync
```

```sh
dart run ../../bin/kmdb.dart demodb sync
dart run ../../bin/kmdb.dart demodb scan notes
```

```sh
dart run ../../bin/kmdb.dart demodb put notes --value '{"title": "demodb"}'
dart run ../../bin/kmdb.dart demodb_2 put notes --value '{"title": "demodb 2"}'
dart run ../../bin/kmdb.dart demodb_3 put notes --value '{"title": "demodb 3"}'
dart run ../../bin/kmdb.dart demodb_4 put notes --value '{"title": "demodb 4"}'

dart run ../../bin/kmdb.dart demodb sync
dart run ../../bin/kmdb.dart demodb_2 sync
dart run ../../bin/kmdb.dart demodb_3 sync
dart run ../../bin/kmdb.dart demodb_4 sync
```

```sh
dart run ../../bin/kmdb.dart demodb sync
dart run ../../bin/kmdb.dart demodb scan notes
```

### A small demo script

```sh
# Create 4 new databases and add a note to each
for db in syncdb_{1..4}; do
    dart run ../../bin/kmdb.dart $db put notes --value "{\"title\": \"Sync note for $db\"}"
done

# Each database instance has its own deviceId, helping us with syncing
for db in syncdb_{1..4}; do
    dart run ../../bin/kmdb.dart $db info
done

# Configure the remotes
for db in syncdb_{1..4}; do
  dart run ../../bin/kmdb.dart $db remote add origin --path $PWD/remote_mount/syncdb
done

# Sync the data
for db in syncdb_{1..4}; do
  dart run ../../bin/kmdb.dart $db sync
done

# Check the notes in each database instance

# syncdb_1 will only have its note
dart run ../../bin/kmdb.dart syncdb_1 scan notes

# syncdb_2 will have its note and the one from syncdb_1
dart run ../../bin/kmdb.dart syncdb_2 scan notes

# syncdb_3 will have its note and the ones from syncdb_1 and syncdb_2
dart run ../../bin/kmdb.dart syncdb_3 scan notes

# syncdb_4 will have all of the notes
dart run ../../bin/kmdb.dart syncdb_4 scan notes
```

## Management

Some handy database management utilities:

```sh
dart run ../../bin/kmdb.dart demodb stats
dart run ../../bin/kmdb.dart demodb info
dart run ../../bin/kmdb.dart demodb verify
dart run ../../bin/kmdb.dart demodb flush
dart run ../../bin/kmdb.dart demodb compact
```

## Deleting the database

To delete the database, just run:

```sh
rm -rf demodb*
rm -rf syncdb*
rm -rf remote_mount
```

## Data prep

You might want to try some data loading and there are some small helper scripts:

- `csv2json.py`: converts a CSV file (with a header row) to JSON.
- `csv2ndjson`: converts a CSV file (with headers) to
  [NDJSON](https://jsonltools.com/what-is-ndjson).

## Sources

- [Weather stations](https://data.un.org/Data.aspx?d=CLINO&f=ElementCode%3A15)
- [ISO 3166-1 (2-digit country-codes)](https://datahub.io/core/country-list)
- [Properties of the elements](https://figshare.com/articles/dataset/Properties_of_the_elements/1295585?file=1873546)
