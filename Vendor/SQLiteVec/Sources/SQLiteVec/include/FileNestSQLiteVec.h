#ifndef FILENEST_SQLITE_VEC_H
#define FILENEST_SQLITE_VEC_H

#include <sqlite3.h>

/// Loads sqlite-vec into one SQLite connection. Returns a SQLite result code.
int filenest_load_sqlite_vec(sqlite3 *database);

#endif
