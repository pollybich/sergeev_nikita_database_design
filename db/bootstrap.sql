-- Только для новой локальной БД. В подготовленной БД преподавателя не требуется.
CREATE SCHEMA IF NOT EXISTS exts;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA exts;
