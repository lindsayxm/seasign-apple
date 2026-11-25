CREATE TABLE `entitlements` (
	`original_transaction_id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`product_id` text NOT NULL,
	`environment` text NOT NULL,
	`state` text NOT NULL,
	`expires_at` integer,
	`revoked_at` integer,
	`signed_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `entitlements_user_id` ON `entitlements` (`user_id`);