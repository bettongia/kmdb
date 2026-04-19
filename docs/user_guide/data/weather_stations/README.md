# Weather stations

This data is based on the Meteostat weather station
[Lite dump](https://bulk.meteostat.net/v2/stations/lite.json.gz). The data is
filtered to only Antarctica-based stations to reduce the file size:

```sh
jq '[ .[] | select(.country == "AQ") ]' lite.json >aq.json
```

Meteostat makes the list of weather stations available under the
[Creative Commons Attribution 4.0 International Public License](https://creativecommons.org/licenses/by/4.0/legalcode).

For further details, please visit the
[Meteostat site](https://dev.meteostat.net/).
