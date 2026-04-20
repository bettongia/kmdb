---
title: KMDB User Guide
subtitle: Getting started
toc-title: "Contents"
...

# Introduction

KMDB is a single-user document database for use in local-first applications.

So what does that mean?

- KMDB stores documents (objects) that you create from JSON objects
- KMDB is run in a single process - it is meant to work in your application and
  isn't designed to be accessed from multiple clients at the same time
- There's no notion of a "user" in KMDB - if you can access the database
  directory and the files within it then KMDB will work
- KMDB is designed so that you can run it locally (e.g. on your laptop) as a
  single instance. You can also synchronise data so that you can work on the
  data from other devices. You don't need a special cloud subscription - you can
  use a local file share or services you may already utilise such as Google
  Drive.

If you are an "Enterprise Architect" for whom everything must be "Enterprise
Ready" (whatever that means to you) then you may need to explore alternatives to
KMDB. If you're a pragmatic application developer, especially one working in
Dart/Flutter then I hope KMDB is useful to you.

Hopefully this tutorial will demonstrate how this all works.

## Why KMDB?

KMDB is written in Dart and aims to be available to Dart and Flutter
applications across all platforms (desktop, mobile, web). In the early stage of
development the focus is on desktop devices.

If you've ever used a document database such as MongoDB, Google Firestore or
CouchDB then you'll have stored something like a JSON object and then been able
to query it. PostgreSQL and SQLite even lets you store JSON objects.

Note: If you're a Dart developer you can store objects via packages such as
[freezed](https://pub.dev/packages/freezed) rather than needing to serialize to
JSON first. The docs aren't built out around this yet but watch this space.

So there's a lot of database systems out there that can do a similar thing so
why bother with KMDB? Well, the database is designed to work with your
application rather than a central database server - you should be able to get up
and running very quickly. SQLite does a wonderful job at this too so, again,
what's different?

KMDB has a core tenet of "local first". This means you should be able to easily
run the database locally without needing a server or paid-for service. This
means it can operate when you're online or offline. The design also aims to make
sure your data doesn't get locked away in some sort of data prison. Whilst
binary formats are used for storage efficiency, the tooling and open-source
nature of the project aims to ensure that data can be easily regained as needed.

Being local first doesn't mean that you're stuck on a single device. KMDB
support synchronisation with a range of endpoints. The first of these is the
local filesystem - allowing you to set up a shared drive, a NAS share or
something like Google Drive or Dropbox shares mapped to a local directory.

KMDB uses file primitives that ensure network issues don't corrupt the database
so you can store both the database instance and a synchronised copy on your NAS
or cloud-based drive/file service.

## What can I do with KMDB?

- Store rich data objects (documents)
- Attach and reference files to those objects
- Utilise synch to share data across devices and support offline storage needs

## Other resources

You can find some other KMDB documentation as your interest directs you:

1. The KMDB Primer is a guide to the internals and how the various components
   interact
2. The KMDB Design and Specification really gets into the nitty-gritty

# Get started with the CLI

We'll start by looking at the KMDB CLI on a desktop device.

## Getting the CLI

## From a release archive (recommended)

Download the latest release archive for your platform from the releases page,
then extract it and add the `bin/` directory to your path:

```sh
tar -xzf kmdb-<version>-<os>-<arch>.tar.gz
export PATH="$PWD/kmdb-<version>-<os>-<arch>/bin:$PATH"
```

### Using the source code

For local development you can run the CLI directly without a full release build:

```sh
cd packages/kmdb_cli
dart run bin/kmdb.dart
```

_Running in the `packages/kmdb_cli` ensures that the various build hooks are
run._

#### Building from source

If you have cloned the repository you can build the CLI directly. You will need
a current Dart SDK installation and Git LFS.

First pull the large model assets tracked with Git LFS:

```sh
git lfs pull
```

Then build and package the CLI for the current platform:

```sh
make release
```

This produces `dist/cli/<os>-<arch>/kmdb-<version>-<os>-<arch>.tar.gz`. Extract
it and add the `bin/` directory to your path as above.

You should be able to run `kmdb`:

```sh
kmdb --help
```

# Before you get started

Working with `kmdb` will create directories that house the database. It's best
to do this in a directory you can try things out. Consider creating a new
directory somewhere handy and work from there.

# Create a database

You can create an empty database using the `init` command. In the call below,
`demodb` provides the location of the database. In this case, a directory
(database) named `demodb` will be created in the current directory.

_Note: you can provide a path for the database such as `kmdb /tmp/mydb init`._

```sh
kmdb demodb init
```

Output:

```json
{
  "path": "demodb",
  "deviceId": "9a83862b",
  "created": true
}
```

You'll see that a `demodb` directory has been created and looks something like
the following:

```
demodb
├── CURRENT
├── DEVICE_ID
├── LOCK
├── MANIFEST-00001
├── README.txt
└── sst
    └── 9a83862b-019D9E2C64420001-019D9E2C64420001.sst
```

KMDB databases are housed in a directory structure - they are not a single file
due to the approach used to provide safe file operations and synchronisation.

If you check out `README.txt` you'll see the following warning:

```
This directory is managed by KMDB. Please DO NOT interact with these files directly or your database will be corrupted.
```

This is important - you should let KMDB manage these files. In a few minutes
we'll look at how you can explore these files safely.

Whilst we used the `init` command to create the database, you can also do this
when you try to insert a new document using the `insert` command against a
database that doesn't already exist.

KMDB works to be as sensible as possible so if you try to create a database that
already exists:

```sh
kmdb demodb init
```

You'll see it's essentially a no-op:

```json
{
  "path": "demodb",
  "deviceId": "9a83862b",
  "created": false
}
```

# Inserting and retrieving documents

KMDB uses Collections to help you organise documents. You could just dump all
your documents into a single collection but that will make things like searching
and indexing not as much fun so we'll be sensible and use collections.

Now you have a nice new database let's create a new document in the `notes`
collection:

```sh
kmdb demodb insert notes --value '{"title": "My very first note."}'
```

The output will be the document added to the database collection:

```json
[
  {
    "title": "My very first note.",
    "_id": "019da788e9dd72be90ebebb9508ebdfd"
  }
]
```

Note: For the most part the pattern
`kmdb <database_path> <command> <collection> ...` is used when working on a
database.

We can check to make sure that we have 1 document in the `notes` collection:

```sh
kmdb demodb count notes
```

The `scan` command returns all documents in the selected collection (e.g.
`notes`):

```sh
kmdb demodb scan notes
```

Now that you've created a new collection (`notes`) and added a document you can
try adding some of your own notes to the database.

# The Document ID

When you created that first note you got the following output:

```json
[
  {
    "title": "My very first note.",
    "_id": "019da788e9dd72be90ebebb9508ebdfd"
  }
]
```

Let's take a moment to understand the `_id` property. This is automatically
created by KMDB as the unique identifier for the document. You can't change that
ID. You also can't try to create a record with your own `_id` - run the
following against your database:

```sh
kmdb demodb insert notes --value '{"_id": 1234, "title": "My ID hack."}'
```

The output will be something like:

```json
[
  {
    "_id": "019da7b033ce7a07a20f8e706d5402d8",
    "title": "My ID hack."
  }
]
```

KMDB silently ignores your `_id` value. Refrain from using top-level properties
with the underscore as a prefix as KMDB treats it as a system-managed property
and will return an error. The `_id` field is a little different though - any
attempt to use it is ignored.

To illustrate, try to be sneaky:

```sh
kmdb demodb insert notes --value '{"_title": "My ID hack."}'
```

... and you'll get the following output:

```
Error: Document contains reserved "_"-prefixed field(s): "_title". The "_" prefix is reserved for KMDB system fields (e.g. "_id").
```

So what is that ID anyway? It's a
[UUIDv7](https://www.rfc-editor.org/rfc/rfc9562.html#name-uuid-version-7) value.

The KMDB spec goes into this topic in more detail.

# Scripts

Scripts allow you to run multiple commands (`insert`, `delete` etc) as a batch.

Start by creating a file named `tags.data`:

```sh
cat <<EOM >tags.data
insert categories --value '{"name":"Work"}'
insert categories --value '{"name":"Personal"}'
EOM
```

The [`tags.data`](tags.data) script adds 2 new documents to the `categories`
collection:

```sh
kmdb demodb --read tags.data
```

You'll see the

```json
[
  {
    "name": "Work",
    "_id": "019da7a9ad44725e8df587e30bd14482"
  }
]
[
  {
    "name": "Personal",
    "_id": "019da7a9ad457009a5e13f9de93025d7"
  }
]
```

Don't forget you can also see all the documents in the `categories` collection
by calling `scan`:

```sh
kmdb demodb scan categories
```

# Importing data

You can load documents from a JSON file - this next call creates a collection
named `weather_stations` and adds details regarding a bunch of weather stations
around the world.

```sh
kmdb demodb insert weather_stations --file data/weather_stations/stations.json
```

How many weather stations do we have?

```sh
kmdb demodb count weather_stations
```

If we run a scan we'll get JSON output by default. However, there are three
handy parameters to help us explore the data:

- `--limit` will limit the number of documents to display
- `--format` allows us to set the output format, including json (default),
  compact, ndjson, table, csv, line
- `--select` lets us list the fields we want to display

We can get a more human-friendly output from `scan` using the following example:

```sh
kmdb demodb scan weather_stations --format=table --select="id,name,location" --limit=20
```

We can also filter for documents - we'll explore this deeper in a while but, for
now, try this query:

```sh
kmdb demodb scan weather_stations --format=table --select="_id,id,name.en" --limit=20 --filter '{"field":"name.en","op":"eq","value":"McMurdo"}'
```

You'll get a result similar to the one below but your `_id` will be different:

```
_id                               id     name
─────────────────────────────────────────────────────────
019da7e30dce7d198a38d98b8eac9164  89664  {"en":"McMurdo"}
```

You can get a specific document using its `_id`. You'll need to adapt the
command below by swapping in the value for `_id` you saw in the previous
response:

```sh
kmdb demodb get weather_stations 019da7e30dce7d198a38d98b8eac9164
```

Let's check which collections we now have (we should have `notes`, `categories`
and `weather_stations`):

```sh
kmdb demodb collections list
```

## Import with NDJSON

kmdb also supports loading from an NDJSON file - let's add in some country
codes:

```sh
kmdb demodb put country_codes --file iso_3166_1.ndjson

kmdb demodb count country_codes
```

We can also load via stdin:

```sh
cat elements.ndjson| kmdb demodb put elements
kmdb demodb count elements
```

# Query

```sh
kmdb demodb scan weather_stations --filter '{"field":"Station Name","op":"eq","value":"MAWSON"}'
```

```sh
kmdb demodb scan weather_stations --filter '{"field":"Station Name","op":"eq","value":"MAWSON"}' --format table

kmdb demodb scan weather_stations --filter '{"field":"Station Name","op":"eq","value":"MAWSON"}' --format csv
```

You can use `jq` to manipulate the default JSON-based output:

```sh
kmdb demodb scan weather_stations --filter '{"field":"Station Name","op":"eq","value":"MAWSON"}' | jq '.[] | {"Country or Territory", "WMO Station Number", "Period"}'
```

But using `--select` and the table mode will give you some nicely formatted
output:

```sh
kmdb demodb scan elements --filter '{"field":"Name","op":"startsWith","value":"H"}' --select Name,Symbol,Atomic_Number --format table
```

## Export/Import

Export lets you export a collection to NDJSON format:

```sh
kmdb demodb export elements --output elements.export
```

## Backups

Let's create a backup:

```sh
kmdb demodb dump --output demodb.dump
```

We can then restore the data to a new copy of the database:

```sh
kmdb demodb_2 restore --input demodb.dump
kmdb demodb_2 collections
```

## Synchronising

```sh
mkdir -p remote_mount/demodb_sync
```

```sh
kmdb demodb remote add origin --path remote_mount/demodb_sync
```

```sh
kmdb demodb remote list
```

```sh
kmdb demodb remote remove origin
kmdb demodb remote add origin --path $PWD/remote_mount/demodb_sync
kmdb demodb remote list
```

```sh
kmdb demodb sync
```

```sh
kmdb demodb_2 scan notes
```

```sh
kmdb demodb scan notes
kmdb demodb insert notes --value '{"title": "Very important note"}'
kmdb demodb sync
```

```sh
kmdb demodb_2 remote add origin --path $PWD/remote_mount/demodb_sync
kmdb demodb_2 remote list
```

```sh
kmdb demodb_2 sync
kmdb demodb_2 scan notes
```

```sh
kmdb demodb_3 init
kmdb demodb_3 remote add origin --path $PWD/remote_mount/demodb_sync
kmdb demodb_3 pull --collection notes
kmdb demodb_3 scan notes
```

We can also `init` a new database and sync across all of the shared collections:

```sh
kmdb demodb_4 init
kmdb demodb_4 remote add origin --path $PWD/remote_mount/demodb_sync
kmdb demodb_4 sync
kmdb demodb_4 collections
kmdb demodb_4 scan notes
kmdb demodb_4 insert notes --value '{"title": "note to self"}'
kmdb demodb_4 sync
```

```sh
kmdb demodb sync
kmdb demodb scan notes
```

```sh
kmdb demodb insert notes --value '{"title": "demodb"}'
kmdb demodb_2 insert notes --value '{"title": "demodb 2"}'
kmdb demodb_3 insert notes --value '{"title": "demodb 3"}'
kmdb demodb_4 insert notes --value '{"title": "demodb 4"}'

kmdb demodb sync
kmdb demodb_2 sync
kmdb demodb_3 sync
kmdb demodb_4 sync
```

```sh
kmdb demodb sync
kmdb demodb scan notes
```

### A small demo script

```sh
# Create 4 new databases and add a note to each
for db in syncdb_{1..4}; do
    kmdb $db insert notes --value "{\"title\": \"Sync note for $db\"}"
done

# Each database instance has its own deviceId, helping us with syncing
for db in syncdb_{1..4}; do
    kmdb $db info
done

# Configure the remotes
for db in syncdb_{1..4}; do
  kmdb $db remote add origin --path $PWD/remote_mount/syncdb
done

# Sync the data
for db in syncdb_{1..4}; do
  kmdb $db sync
done

# Check the notes in each database instance

# syncdb_1 will only have its note
kmdb syncdb_1 scan notes

# syncdb_2 will have its note and the one from syncdb_1
kmdb syncdb_2 scan notes

# syncdb_3 will have its note and the ones from syncdb_1 and syncdb_2
kmdb syncdb_3 scan notes

# syncdb_4 will have all of the notes
kmdb syncdb_4 scan notes
```

### A note about Copying the database directory

```sh
kmdb copydb_og insert notes --value '{"title": "Original note"}'
kmdb copydb_og scan notes

# Use the filesystem to copy the database directory:
cp -R copydb_og copydb_copy

# We should see the original note:
kmdb copydb_copy scan notes

kmdb copydb_og info | jq '.deviceId'
kmdb copydb_copy info | jq '.deviceId'

# Configure a remote
kmdb copydb_og remote add origin --path $PWD/remote_mount/copydb_sync
kmdb copydb_copy remote add origin --path $PWD/remote_mount/copydb_sync

# When you now sync you'll see that it looks like the data is from the same deviceId
kmdb copydb_og sync
kmdb copydb_copy sync

# So create a new note and sync it
kmdb copydb_og insert notes --value '{"title": "Original note - the sequel"}'
kmdb copydb_og scan notes
kmdb copydb_og sync

# Sync to the copy
kmdb copydb_copy sync

# The scan unfortunately displays only 1 note:
kmdb copydb_copy scan notes
```

The issue is that `copydb_copy` has the same deviceId and kmdb gets a bit
confused. So we need to set a new device ID for the copy:

```sh
kmdb copydb_copy info
kmdb copydb_copy new-device-id
kmdb copydb_copy info
```

You should see the device ID has changed. You will also see the following
warning from the call to `new-device-id` (your list of `hwm` files will be
different):

```
Warning: this database has 1 configured remote(s). After syncing with the new device ID, delete the stale highwater mark file(s) from each remote sync folder:
  highwater/2e8e43cb.hwm
```

First up, let's perform the sync:

```sh
kmdb copydb_copy sync
```

Then delete the `hwm` files (change the command to match the file you saw in
your warning):

```sh
rm remote_mount/copydb_sync/highwater/1a62a005.hwm
```

```sh
kmdb copydb_copy scan notes
kmdb copydb_copy sync

echo After sync:
kmdb copydb_copy scan notes
```

Let's do one final check and create a new note in `copydb_og`:

```sh
kmdb copydb_og insert notes --value '{"title": "Synco noto"}'
kmdb copydb_og scan notes
kmdb copydb_og sync
```

Finally, we'll sync `copydb_copy` and check if we got the note:

```sh
kmdb copydb_copy sync
kmdb copydb_copy scan notes
```

## Management

Some handy database management utilities:

```sh
kmdb demodb stats
kmdb demodb info
kmdb demodb verify
kmdb demodb flush
kmdb demodb compact
```

## Deleting the database

To delete the database, just run:

```sh
rm -rf demodb*
rm -rf syncdb*
rm -rf copydb*
rm -rf remote_mount
```

## Sources

- [Weather stations](https://data.un.org/Data.aspx?d=CLINO&f=ElementCode%3A15)
-
-
