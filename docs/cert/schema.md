# Certifications Tracker schema

Migrations: [`20261124120000_cert_certifications.sql`](../../supabase/migrations/20261124120000_cert_certifications.sql) (certifications) and [`20261125120000_cert_courses.sql`](../../supabase/migrations/20261125120000_cert_courses.sql) (price on certifications, courses).

| Table | What it holds |
|---|---|
| `cert_certifications` | One certification: `name`, `provider`, `earnDate`, optional `expirationDate` (null = never expires), optional `verificationUrl` (http/https), `tags` (`text[]`, lower-case labels such as `cloud`, `azure`), `pdfPath` in Storage and `price` (default 0). |
| `cert_courses` | One course taken: `name`, `provider` (where: Udemy, LinkedIn Learning, ...), `price` (default 0), `earnDate`, `hours`, `tags` (`text[]`, the dashboard categories) and `filePath` in Storage. Never mixed with certifications. |

- Has `"userId"` and the four RLS policies (`auth.uid() = "userId"`); `anon` has no access.
- Soft-deleted (`deletedAt`). Tags are not a separate table: the app builds the tag suggestions and the per-tag counts from the rows.
- Certification PDFs go to the private bucket `cert-pdfs` under `<userId>/<certificationId>.pdf`; course files under `<userId>/courses/<courseId>.<ext>` (20 MB; PDF, JPEG or PNG). Policies let a user touch only their own folder.
