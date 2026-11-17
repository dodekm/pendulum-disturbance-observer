#include "AeroShield.h"

#include <Arduino.h>
#include <UartLink.h>
#include <math.h>
#include <string.h>

namespace {

constexpr float kSamplingPeriodSeconds = 0.05F;
constexpr unsigned long kBaudRate = 250000UL;
constexpr uartlink::StreamId kControlStream = 1U;

// Waiting for at most three nominal sample periods prevents a failed sensor or
// timer from blocking the communication server forever.
constexpr uint32_t kSampleWaitTimeoutMs = 150U;

// A short request poll keeps loop() responsive when no MATLAB client is active.
constexpr uint32_t kRequestPollTimeoutMs = 20U;
constexpr uint32_t kTransactionReadTimeoutMs = 250U;
constexpr uint32_t kTransactionWriteTimeoutMs = 250U;

class AeroShieldTimestampSource final : public uartlink::TimestampSource {
public:
    uartlink::Timestamp now() noexcept override {
        return static_cast<uartlink::Timestamp>(AeroShield.getTick()) *
               kSamplingPeriodSeconds;
    }
};

class AeroShieldRequestHandler final : public uartlink::RequestHandler {
public:
    uartlink::Status read(
        const uartlink::StreamId stream_id,
        const uartlink::MutableBuffer payload) noexcept override {
        if (stream_id != kControlStream || payload.size != sizeof(float)) {
            return uartlink::Status::handler_error;
        }

        const uint32_t wait_started_ms = millis();
        while (!AeroShield.isSampleAvailable()) {
            if (static_cast<uint32_t>(millis() - wait_started_ms) >=
                kSampleWaitTimeoutMs) {
                return uartlink::Status::handler_error;
            }
            yield();
        }

        const float angle_degrees = AeroShield.sensorReadDegreeSampled();
        ::memcpy(payload.data, &angle_degrees, sizeof(angle_degrees));
        return uartlink::Status::ok;
    }

    uartlink::Status write(
        const uartlink::StreamId stream_id,
        const uartlink::ConstBuffer payload,
        const uartlink::Timestamp sender_timestamp) noexcept override {
        if (stream_id != kControlStream || payload.size != sizeof(float)) {
            return uartlink::Status::handler_error;
        }

        float actuator_command = 0.0F;
        ::memcpy(&actuator_command, payload.data, sizeof(actuator_command));

        // Reject NaN and infinities before they reach the actuator. AeroShield
        // retains responsibility for applying its documented finite-value range.
        if (!isfinite(actuator_command)) {
            return uartlink::Status::handler_error;
        }

        AeroShield.actuatorWrite(actuator_command);
        last_command_timestamp_ = sender_timestamp;
        return uartlink::Status::ok;
    }

    uartlink::Timestamp lastCommandTimestamp() const noexcept {
        return last_command_timestamp_;
    }

private:
    uartlink::Timestamp last_command_timestamp_ = 0.0F;
};

uartlink::ArduinoStream serial_transport(Serial);
AeroShieldTimestampSource timestamp_source;
AeroShieldRequestHandler request_handler;

const uartlink::Options protocol_options(
    kTransactionReadTimeoutMs,
    kTransactionWriteTimeoutMs);

uartlink::Server server(
    serial_transport,
    request_handler,
    &timestamp_source,
    protocol_options);

// Useful debugger watch expressions; neither is transmitted on the protocol
// UART, so diagnostics cannot corrupt communication.
uartlink::Status last_server_status = uartlink::Status::ok;


}  // namespace

void setup() {


    Serial.begin(kBaudRate);

    // AeroShield.begin_throttle_calibrate();

    while (!AeroShield.begin(kSamplingPeriodSeconds)) {
    }


}

void loop() {
    server.serveOne(kRequestPollTimeoutMs);
}
