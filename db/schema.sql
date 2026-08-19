-- DSP-Seed-Finder galaxy database. Column order mirrors dsp_seed dump TSVs.
-- Big tables get DATA DIRECTORY='/galaxydb' once the Datastore volume exists;
-- for now they are created wherever the server datadir lives.
-- Secondary indexes are added AFTER bulk load (see indexes.sql).

CREATE DATABASE IF NOT EXISTS galaxy
  DEFAULT CHARACTER SET ascii COLLATE ascii_bin;
USE galaxy;

CREATE TABLE IF NOT EXISTS galaxies (
  star_count    TINYINT UNSIGNED NOT NULL,
  seed          INT UNSIGNED NOT NULL,
  bh_count      TINYINT UNSIGNED NOT NULL,
  ns_count      TINYINT UNSIGNED NOT NULL,
  wd_count      TINYINT UNSIGNED NOT NULL,
  giant_count   TINYINT UNSIGNED NOT NULL,
  o_count       TINYINT UNSIGNED NOT NULL,
  b_count       TINYINT UNSIGNED NOT NULL,
  a_count       TINYINT UNSIGNED NOT NULL,
  f_count       TINYINT UNSIGNED NOT NULL,
  g_count       TINYINT UNSIGNED NOT NULL,
  k_count       TINYINT UNSIGNED NOT NULL,
  m_count       TINYINT UNSIGNED NOT NULL,
  planet_count  SMALLINT UNSIGNED NOT NULL,
  gas_giant_count SMALLINT UNSIGNED NOT NULL,
  tidal_count   SMALLINT UNSIGNED NOT NULL,
  habitable_count SMALLINT UNSIGNED NOT NULL,
  min_bh_dist   FLOAT NOT NULL,   -- -1 when no black hole
  min_ns_dist   FLOAT NOT NULL,   -- -1 when no neutron star
  v_iron BIGINT UNSIGNED NOT NULL, v_copper BIGINT UNSIGNED NOT NULL,
  v_silicium BIGINT UNSIGNED NOT NULL, v_titanium BIGINT UNSIGNED NOT NULL,
  v_stone BIGINT UNSIGNED NOT NULL, v_coal BIGINT UNSIGNED NOT NULL,
  v_oil BIGINT UNSIGNED NOT NULL, v_fireice BIGINT UNSIGNED NOT NULL,
  v_diamond BIGINT UNSIGNED NOT NULL, v_fractal BIGINT UNSIGNED NOT NULL,
  v_crysrub BIGINT UNSIGNED NOT NULL, v_grat BIGINT UNSIGNED NOT NULL,
  v_bamboo BIGINT UNSIGNED NOT NULL, v_mag BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (star_count, seed)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS stars (
  star_count    TINYINT UNSIGNED NOT NULL,
  seed          INT UNSIGNED NOT NULL,
  idx           TINYINT UNSIGNED NOT NULL,
  star_type     TINYINT UNSIGNED NOT NULL,  -- 0 mainseq 1 giant 2 wd 3 ns 4 bh
  spectr        TINYINT NOT NULL,           -- game values: M=-4..O=2,X=3
  luminosity    FLOAT NOT NULL,
  radius        FLOAT NOT NULL,
  mass          FLOAT NOT NULL,
  age           FLOAT NOT NULL,
  temperature   FLOAT NOT NULL,
  pos_x FLOAT NOT NULL, pos_y FLOAT NOT NULL, pos_z FLOAT NOT NULL,
  birth_dist    FLOAT NOT NULL,
  dyson_radius  INT UNSIGNED NOT NULL,
  habitable_radius FLOAT NOT NULL,
  light_balance_radius FLOAT NOT NULL,
  resource_coef FLOAT NOT NULL,
  max_hive      TINYINT UNSIGNED NOT NULL,
  initial_hive  TINYINT UNSIGNED NOT NULL,
  planet_count  TINYINT UNSIGNED NOT NULL,
  gas_giant_count TINYINT UNSIGNED NOT NULL,
  tidal_count   TINYINT UNSIGNED NOT NULL,
  satellite_count TINYINT UNSIGNED NOT NULL,
  in_dyson_count TINYINT UNSIGNED NOT NULL,
  v_iron INT UNSIGNED NOT NULL, v_copper INT UNSIGNED NOT NULL,
  v_silicium INT UNSIGNED NOT NULL, v_titanium INT UNSIGNED NOT NULL,
  v_stone INT UNSIGNED NOT NULL, v_coal INT UNSIGNED NOT NULL,
  v_oil INT UNSIGNED NOT NULL, v_fireice INT UNSIGNED NOT NULL,
  v_diamond INT UNSIGNED NOT NULL, v_fractal INT UNSIGNED NOT NULL,
  v_crysrub INT UNSIGNED NOT NULL, v_grat INT UNSIGNED NOT NULL,
  v_bamboo INT UNSIGNED NOT NULL, v_mag INT UNSIGNED NOT NULL,
  PRIMARY KEY (star_count, seed, idx)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS planets (
  star_count    TINYINT UNSIGNED NOT NULL,
  seed          INT UNSIGNED NOT NULL,
  star_idx      TINYINT UNSIGNED NOT NULL,
  planet_idx    TINYINT UNSIGNED NOT NULL,
  theme_id      TINYINT UNSIGNED NOT NULL,
  algo_id       TINYINT UNSIGNED NOT NULL,
  planet_type   TINYINT UNSIGNED NOT NULL,  -- 0 none 1 volcano 2 ocean 3 desert 4 ice 5 gas
  is_gas_giant  TINYINT UNSIGNED NOT NULL,
  orbit_around  TINYINT NOT NULL,           -- parent planet index, -1 = star
  orbit_index   TINYINT UNSIGNED NOT NULL,
  orbit_radius  FLOAT NOT NULL,
  sun_distance  FLOAT NOT NULL,
  orbital_period DOUBLE NOT NULL,
  rotation_period DOUBLE NOT NULL,
  tidal_locked  TINYINT UNSIGNED NOT NULL,
  resonance     TINYINT UNSIGNED NOT NULL,
  obliquity     FLOAT NOT NULL,
  water_item_id SMALLINT NOT NULL,          -- 0 none, 1000 water, -2 lava, 1116 sulfur
  gas1_item SMALLINT NOT NULL, gas1_rate FLOAT NOT NULL,
  gas2_item SMALLINT NOT NULL, gas2_rate FLOAT NOT NULL,
  gas3_item SMALLINT NOT NULL, gas3_rate FLOAT NOT NULL,
  v_iron INT UNSIGNED NOT NULL, v_copper INT UNSIGNED NOT NULL,
  v_silicium INT UNSIGNED NOT NULL, v_titanium INT UNSIGNED NOT NULL,
  v_stone INT UNSIGNED NOT NULL, v_coal INT UNSIGNED NOT NULL,
  v_oil INT UNSIGNED NOT NULL, v_fireice INT UNSIGNED NOT NULL,
  v_diamond INT UNSIGNED NOT NULL, v_fractal INT UNSIGNED NOT NULL,
  v_crysrub INT UNSIGNED NOT NULL, v_grat INT UNSIGNED NOT NULL,
  v_bamboo INT UNSIGNED NOT NULL, v_mag INT UNSIGNED NOT NULL,
  PRIMARY KEY (star_count, seed, star_idx, planet_idx)
) ENGINE=InnoDB;
