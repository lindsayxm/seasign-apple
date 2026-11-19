// Drizzle schema for D1. Generate migrations into ../migrations with
// `npx drizzle-kit generate`; apply them locally with
// `npx wrangler d1 migrations apply seasign --local`.
//
// Nothing here imports `cloudflare:*`, so the spec writer can load it in Node.
import { index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

/**
 * One Google Calendar push channel (task 156, plan
 * plans/2026-11-19-google-calendar-push.md). Google calls the webhook with the
 * channel id and token; the row says which phone to wake. It holds no Google
 * token, no calendar id, no user id and no event data: a leaked row says only
 * "this phone watches some calendar until then".
 */
export const calendarChannels = sqliteTable(
  "calendar_channels",
  {
    /** Our random channel id, sent to Google as the channel's `id` and back to us in X-Goog-Channel-ID. */
    id: text("id").primaryKey(),
    /** Lowercase hex SHA-256 of the channel token (X-Goog-Channel-Token). The token itself is not kept. */
    tokenHash: text("token_hash").notNull(),
    /** Google's resourceId from the watch answer; channels.stop needs it. */
    resourceId: text("resource_id").notNull(),
    /** The APNs device token, lowercase hex. */
    deviceToken: text("device_token").notNull(),
    /** Which APNs host the device token belongs to. */
    environment: text("environment", { enum: ["sandbox", "production"] }).notNull(),
    /** When Google stops the channel, Unix milliseconds. */
    expiresAt: integer("expires_at").notNull(),
    /** When the row was written, Unix milliseconds. */
    createdAt: integer("created_at").notNull(),
  },
  (table) => [index("calendar_channels_device_token").on(table.deviceToken), index("calendar_channels_expires_at").on(table.expiresAt)],
);

export type CalendarChannel = typeof calendarChannels.$inferSelect;
