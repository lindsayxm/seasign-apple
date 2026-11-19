CREATE TABLE `calendar_channels` (
	`id` text PRIMARY KEY NOT NULL,
	`token_hash` text NOT NULL,
	`resource_id` text NOT NULL,
	`device_token` text NOT NULL,
	`environment` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `calendar_channels_device_token` ON `calendar_channels` (`device_token`);--> statement-breakpoint
CREATE INDEX `calendar_channels_expires_at` ON `calendar_channels` (`expires_at`);