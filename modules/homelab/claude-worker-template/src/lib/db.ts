// src/lib/db.ts
// Pre-configured PostgreSQL connection pool.
// Import this in any +server.ts file that needs database access:
//   import pool from '$lib/db';
//   const result = await pool.query('SELECT * FROM items');

import pg from 'pg';

const pool = new pg.Pool({
  connectionString: 'postgresql://claude@localhost/claude',
});

export default pool;
