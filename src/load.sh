#!/bin/bash

TABLES="agency calendar calendar_dates routes shapes stop_times stops trips transfers frequencies fare_attributes fare_rules"

# This script takes two arguments: 
# A zip file containing gtfs files, and a set of psql flags
ZIP=$1
PSQLFLAGS=${*/$1/ }

FILES=$(unzip -l "${ZIP}" | awk '{print $NF}' | grep .txt)
set -e

# Called with name of table
function import_stdin()
{
    local hed
    # remove possible BOM
    hed=$(unzip -p "$ZIP" "${1}.txt" | head -n 1 | awk '{sub(/^\xef\xbb\xbf/,"")}{print}')
    echo "COPY gtfs_${1}" 1>&2
    unzip -p "$ZIP" "${1}.txt" | psql ${PSQLFLAGS} -c "COPY gtfs_${1} (${hed}) FROM STDIN WITH DELIMITER AS ',' HEADER CSV"
}

ADD_DATES=
# Insert feed info
if [[ "${FILES/feed_info}" != "$FILES" ]]; then
    # Contains feed info, so load that into the table
    echo "Loading feed_info from dataset"
    import_stdin "feed_info"
else
    ADD_DATES=true
    # get the min and max calendar dates for this
    echo "No feed_info file found, constructing one"
    echo "INSERT INTO gtfs_feed_info" 1>&2
    psql ${PSQLFLAGS} -c "INSERT INTO gtfs_feed_info (feed_file) VALUES ('$1');"
fi

# Save the current feed_index
feed_index=$(psql ${PSQLFLAGS} --pset format=unaligned -t -c "SELECT max(feed_index) FROM gtfs_feed_info")

echo "SET feed_index = $feed_index" 1>&2

# for each table, check if file exists
for table in $TABLES; do
    if [[ ${FILES/${table}.txt} != "$FILES" ]]; then
        # set default feed_index
        psql ${PSQLFLAGS} -c "ALTER TABLE gtfs_${table} ALTER COLUMN feed_index SET DEFAULT ${feed_index}"

        # read it into db
        import_stdin "$table"

        # unset default feed_index
        psql ${PSQLFLAGS} -c "ALTER TABLE gtfs_${table} ALTER COLUMN feed_index DROP DEFAULT"
    fi
done

if [ -n "$ADD_DATES" ]; then
    echo "UPDATE gtfs_feed_info"
    psql ${PSQLFLAGS} -c "UPDATE gtfs_feed_info SET feed_start_date=s, feed_end_date=e FROM (SELECT MIN(start_date) AS s, MAX(end_date) AS e FROM gtfs_calendar WHERE feed_index=${feed_index}) a WHERE feed_index = ${feed_index}"
else
    psql ${PSQLFLAGS} -c "UPDATE gtfs_feed_info SET feed_file ='$1' WHERE feed_index = ${feed_index}"
fi