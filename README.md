# supabase

Database schema for every app that shares the `danny270793` Supabase project. All migrations live here. The app repos no longer keep their own `supabase/` folder.

## Apps and table prefixes

The apps share one `public` schema and one `auth.users` table, so every table, view, type, and function starts with the app's prefix.

| App | Repo | Prefix |
|---|---|---|
| Wallet | [danny270793/Wallet](https://github.com/danny270793/Wallet) | `wallet_` |
| Family Games | [danny270793/Family-Games](https://github.com/danny270793/Family-Games) | `fg_` |
| Habit Tracker | [danny270793/Time-Tracker](https://github.com/danny270793/Time-Tracker) | `habit_tracker_` |
| Hangman | [danny270793/Hangman](https://github.com/danny270793/Hangman) | `hangman_` |
| MyPills | [danny270793/MyPills](https://github.com/danny270793/MyPills) | `health_` |

Accounts are shared: a user who signs up in one app can sign in to the others with the same email and password.

## Link the project

```sh
supabase login
supabase link --project-ref <project-ref>
```

The project ref is the subdomain of `SUPABASE_URL` in the apps' `.env.json`.

## Add a migration

1. Create the file:

   ```sh
   supabase migration new <prefix>_<change>
   ```

2. Write the SQL. Prefix every new object with the app's prefix, enable row level security on every table, and revoke access from `anon` unless the app really needs it.
3. Test it against a local database. This needs Docker:

   ```sh
   supabase start
   supabase db reset   # local only: rebuilds from every migration
   ```

4. Apply it to the shared project:

   ```sh
   supabase db push
   ```

Never run `supabase db reset --linked`. It drops the tables of every app.

## App docs

- [Hangman words schema](docs/hangman/words-schema.md)
- [Hangman game records](docs/hangman/game-records-table.md)
- [Hangman difficulty calculation](docs/hangman/difficulty-calculation.md)
