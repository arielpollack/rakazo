-- A bot's computer can be its owner's own paired device.
ALTER TABLE "computers" ADD COLUMN "deviceId" TEXT;

CREATE INDEX "computers_deviceId_idx" ON "computers"("deviceId");

ALTER TABLE "computers" ADD CONSTRAINT "computers_deviceId_fkey" FOREIGN KEY ("deviceId") REFERENCES "user_devices"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- The model providers a paired computer signs in to by itself, for the bots that run on it.
ALTER TABLE "user_devices" ADD COLUMN "modelProviders" TEXT[] DEFAULT ARRAY[]::TEXT[];
