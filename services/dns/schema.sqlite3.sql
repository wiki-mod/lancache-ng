-- Vendored third-party file (Rule-Ref: AG-HDR-004, same carve-out already
-- applied to services/proxy/public_suffix_list.dat): this is PowerDNS
-- Authoritative Server's own gsqlite3 backend schema
-- (modules/gsqlite3backend/schema.sqlite3.sql, PowerDNS/pdns upstream
-- project, GPL-licensed there -- not lancache-ng's own AGPL-licensed
-- source, so no SPDX-License-Identifier line is added here), fetched
-- byte-for-byte via the GitHub API from upstream tag auth-5.0.5
-- (https://github.com/PowerDNS/pdns/blob/auth-5.0.5/modules/gsqlite3backend/schema.sqlite3.sql)
-- and reproduced unmodified below except for this explanatory comment block,
-- which documents lancache-ng's own reason for vendoring it -- matching the
-- pdns-backend-sqlite3 package this image installs from Alpine (issue
-- #815's services/dns Alpine migration).
--
-- WHY this file exists in this repo at all: Debian's pdns-backend-sqlite3
-- package ships this same schema file under
-- /usr/share/pdns-backend-sqlite3/schema/schema.sqlite3.sql, and
-- entrypoint.sh's original bootstrap logic located it there generically via
-- `find /usr/share -name schema.sqlite3.sql`. Alpine's pdns-backend-sqlite3
-- package does NOT ship this file at all (confirmed empirically, 2026-08-05,
-- on a real Alpine 3.24 container: `apk info -L pdns-backend-sqlite3` lists
-- only usr/lib/pdns/pdns/libgsqlite3backend.so, no schema/doc files
-- whatsoever) -- so a first boot on the Alpine image would otherwise fail
-- closed with "sqlite schema not found in /usr/share" and never create a
-- usable database. Vendoring this file lets entrypoint.sh fall back to it
-- when the generic `find` comes up empty, on either base OS.
--
-- Confirmed unchanged across the 4.9->5.0 major-version jump this migration
-- makes: upstream's modules/gsqlite3backend/ directory carries a chain of
-- versioned migration files (e.g. 4.3.1_to_4.7.0_schema.sqlite3.sql) for
-- every schema revision, and the newest such migration file present at the
-- auth-5.0.5 tag is 4.3.1_to_4.7.0 -- there is no 4.7.0-or-later migration
-- file, meaning the base schema below is identical to whatever Debian
-- trixie's own pdns-backend-sqlite3 (4.9.16) already uses. Live-verified
-- further: `pdnsutil create-zone`, `import-tsig-key`, and `set-meta` (the
-- exact pdnsutil subcommands entrypoint.sh calls) all ran successfully
-- against a database initialized from this exact file on pdns-server 5.0.5.
PRAGMA foreign_keys = 1;

CREATE TABLE domains (
  id                    INTEGER PRIMARY KEY,
  name                  VARCHAR(255) NOT NULL COLLATE NOCASE,
  master                VARCHAR(128) DEFAULT NULL,
  last_check            INTEGER DEFAULT NULL,
  type                  VARCHAR(8) NOT NULL,
  notified_serial       INTEGER DEFAULT NULL,
  account               VARCHAR(40) DEFAULT NULL,
  options               VARCHAR(65535) DEFAULT NULL,
  catalog               VARCHAR(255) DEFAULT NULL
);

CREATE UNIQUE INDEX name_index ON domains(name);
CREATE INDEX catalog_idx ON domains(catalog);


CREATE TABLE records (
  id                    INTEGER PRIMARY KEY,
  domain_id             INTEGER DEFAULT NULL,
  name                  VARCHAR(255) DEFAULT NULL,
  type                  VARCHAR(10) DEFAULT NULL,
  content               VARCHAR(65535) DEFAULT NULL,
  ttl                   INTEGER DEFAULT NULL,
  prio                  INTEGER DEFAULT NULL,
  disabled              BOOLEAN DEFAULT 0,
  ordername             VARCHAR(255),
  auth                  BOOL DEFAULT 1,
  FOREIGN KEY(domain_id) REFERENCES domains(id) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX records_lookup_idx ON records(name, type);
CREATE INDEX records_lookup_id_idx ON records(domain_id, name, type);
CREATE INDEX records_order_idx ON records(domain_id, ordername);


CREATE TABLE supermasters (
  ip                    VARCHAR(64) NOT NULL,
  nameserver            VARCHAR(255) NOT NULL COLLATE NOCASE,
  account               VARCHAR(40) NOT NULL
);

CREATE UNIQUE INDEX ip_nameserver_pk ON supermasters(ip, nameserver);


CREATE TABLE comments (
  id                    INTEGER PRIMARY KEY,
  domain_id             INTEGER NOT NULL,
  name                  VARCHAR(255) NOT NULL,
  type                  VARCHAR(10) NOT NULL,
  modified_at           INT NOT NULL,
  account               VARCHAR(40) DEFAULT NULL,
  comment               VARCHAR(65535) NOT NULL,
  FOREIGN KEY(domain_id) REFERENCES domains(id) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX comments_idx ON comments(domain_id, name, type);
CREATE INDEX comments_order_idx ON comments (domain_id, modified_at);


CREATE TABLE domainmetadata (
 id                     INTEGER PRIMARY KEY,
 domain_id              INT NOT NULL,
 kind                   VARCHAR(32) COLLATE NOCASE,
 content                TEXT,
 FOREIGN KEY(domain_id) REFERENCES domains(id) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX domainmetaidindex ON domainmetadata(domain_id);


CREATE TABLE cryptokeys (
 id                     INTEGER PRIMARY KEY,
 domain_id              INT NOT NULL,
 flags                  INT NOT NULL,
 active                 BOOL,
 published              BOOL DEFAULT 1,
 content                TEXT,
 FOREIGN KEY(domain_id) REFERENCES domains(id) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX domainidindex ON cryptokeys(domain_id);


CREATE TABLE tsigkeys (
 id                     INTEGER PRIMARY KEY,
 name                   VARCHAR(255) COLLATE NOCASE,
 algorithm              VARCHAR(50) COLLATE NOCASE,
 secret                 VARCHAR(255)
);

CREATE UNIQUE INDEX namealgoindex ON tsigkeys(name, algorithm);
