#include <Arduino.h>

// pic18f serial ===

#define SER_CLK PD2
#define SER_DAT PD3
#define SER_MASK ~((1 << SER_CLK) | (1 << SER_DAT))
#define NOP __asm__ __volatile__ ("nop")

#define PIC_RESET 4
#define PIC_STATUS 13

void serial_init() {
    pinMode(SER_CLK, OUTPUT);
}

// note: doesnt delay after or before write
void serial_send_byte(unsigned char byte) {
    pinMode(SER_DAT, OUTPUT);
    PORTD &= SER_MASK;

    unsigned char i = 0b10000000;
    while (i) {
        if (byte & i) {
            PORTD |= (1 << SER_DAT);
        }
        PORTD |= (1 << SER_CLK);
        NOP;
        PIND |= (1 << SER_CLK);
        i >>= 1;
        PORTD &= SER_MASK;
    }
}

void serial_send_bytes(uint8_t b1, uint8_t b2, uint8_t b3, uint8_t b4) {
    uint8_t send_buf[4] = { b1, b2, b3, b4 };

    pinMode(SER_DAT, OUTPUT);
    PORTD &= SER_MASK;

    for(unsigned int i = 0; i < 4; i++) {
        uint8_t byte = send_buf[i];

        uint8_t mask = 0b10000000;
        while (mask) {
            if (byte & mask) {
                PORTD |= (1 << SER_DAT);
            }
            PORTD |= (1 << SER_CLK);
            NOP;
            PIND |= (1 << SER_CLK);
            mask >>= 1;
            PORTD &= SER_MASK;
        }
    }
}

void serial_send_bytes_shifted(uint8_t command, uint8_t b1, uint8_t b2, uint8_t b3) {
    uint8_t send_buf[4] = {
        command,
        (b1 << 1) | (b2 >> 7),
        (b2 << 1) | (b3 >> 7),
        b3 << 1,
    };

    pinMode(SER_DAT, OUTPUT);
    PORTD &= SER_MASK;

    for(unsigned int i = 0; i < 4; i++) {
        uint8_t byte = send_buf[i];

        uint8_t mask = 0b10000000;
        while (mask) {
            if (byte & mask) {
                PORTD |= (1 << SER_DAT);
            }
            PORTD |= (1 << SER_CLK);
            NOP;
            PIND |= (1 << SER_CLK);
            mask >>= 1;
            PORTD &= SER_MASK;
        }
    }
}

/*
// note: doesnt delay after or before write
unsigned char serial_read() {
    pinMode(SER_DAT, INPUT);
    // ?
    // pinMode(SER_DAT, INPUT_PULLUP);

    unsigned char byte = 0;

    for (int i = 0; i < 8; i++) {
        digitalWrite(SER_CLK, HIGH);
        byte |= digitalRead(SER_DAT) == HIGH ? 1: 0;
        byte <<= 1;
        digitalWrite(SER_CLK, LOW);
    }

    return byte;
}
*/

//

void start_programming() {
    digitalWrite(PIC_RESET, LOW);
    // TODO wait
    serial_send_bytes((uint8_t)'M', (uint8_t)'H', (uint8_t)'C', (uint8_t)'P');
    // TODO wait
}

void stop_programming() {
    digitalWrite(PIC_RESET, HIGH);
}

#define BUF_SZ 256
uint8_t buf[BUF_SZ] = { 0 };
unsigned int buf_at = 0;

// 3 proglen 2 eepromlen 2 config mask
#define PROG_INFO_LEN (3 + 2 + 2)
uint8_t prog_info[PROG_INFO_LEN] = { 0 };
unsigned int prog_info_at = 0;

uint32_t prog_len = 0;
uint32_t eeprom_len = 0;
uint32_t cfg_mask = 0;

uint32_t prog_recv = 0;
uint32_t eeprom_recv = 0;
uint32_t cfg_mask_temp = 0;

typedef enum {
    STATE_READY,
    STATE_PROG_INFO,
    STATE_PROGMEM,
    STATE_EEPROM,
    STATE_CONFIG,
} State;

State state;

void setup() {
    Serial.begin(19200);
    serial_init();

    pinMode(PIC_RESET, OUTPUT);
    pinMode(PIC_STATUS, OUTPUT);
    digitalWrite(PIC_STATUS, HIGH);

    state = STATE_READY;
}

void loop() {
    if (Serial.available() > 0) {
        uint8_t byte = Serial.read();

        switch(state) {
            case STATE_READY:
                prog_info_at = 0;
                state = STATE_PROG_INFO;
                break;
            case STATE_PROG_INFO:
                prog_info[prog_info_at] = byte;
                prog_info_at += 1;
                if (prog_info_at >= PROG_INFO_LEN) {
                    prog_len = ((uint32_t)prog_info[0] << 16) |
                               (prog_info[1] << 8) |
                               (prog_info[2]);
                    eeprom_len = (prog_info[3] << 8) |
                                 (prog_info[4]);
                    cfg_mask = (prog_info[5] << 8) |
                               (prog_info[6]);
                    cfg_mask_temp = 0b1000000000;
                    prog_recv = 0;
                    state = STATE_PROGMEM;
                    buf_at = 0;
                    digitalWrite(PIC_STATUS, LOW);

                    start_programming();
                }
                break;
            case STATE_PROGMEM:
                buf[buf_at] = byte;
                buf_at += 1;
                if (buf_at >= BUF_SZ) {
                    while (buf_at) {
                        serial_send_bytes_shifted(0xE0, 0x00, buf[BUF_SZ - buf_at], buf[BUF_SZ - buf_at + 1]);
                        // TODO wait
                        buf_at -= 2;
                    }
                }

                prog_recv += 1;
                if (prog_recv == prog_len) {
                    while (buf_at) {
                        serial_send_bytes_shifted(0xE0, 0x00, buf[prog_len - buf_at], buf[prog_len - buf_at + 1]);
                        // TODO wait
                        buf_at -= 2;
                    }

                    if (eeprom_len > 0) {
                        serial_send_bytes_shifted(0x80, 0x38, 0x00, 0x00);
                        eeprom_recv = 0;
                        state = STATE_EEPROM;
                    } else if (cfg_mask) {
                        serial_send_bytes_shifted(0x80, 0x30, 0x00, 0x00);
                        state = STATE_CONFIG;
                    } else {
                        stop_programming();

                        digitalWrite(PIC_STATUS, HIGH);
                        state = STATE_READY;
                    }
                    buf_at = 0;
                }
                break;
            case STATE_EEPROM:
                buf[buf_at] = byte;
                buf_at += 1;
                if (buf_at >= BUF_SZ) {
                    while (buf_at) {
                        serial_send_bytes_shifted(0xE0, 0x00, 0x00, buf[BUF_SZ - buf_at]);
                        // TODO wait
                        buf_at -= 1;
                    }
                }

                eeprom_recv += 1;
                if (eeprom_recv == eeprom_len) {
                    while (buf_at) {
                        serial_send_bytes_shifted(0xE0, 0x00, 0x00, buf[BUF_SZ - buf_at]);
                        // TODO wait
                        buf_at -= 1;
                    }

                    if (cfg_mask) {
                        serial_send_bytes_shifted(0x80, 0x30, 0x00, 0x00);
                        state = STATE_CONFIG;
                    } else {
                        stop_programming();

                        digitalWrite(PIC_STATUS, HIGH);
                        state = STATE_READY;
                    }

                    buf_at = 0;
                }
                break;
            case STATE_CONFIG:
                if (cfg_mask & cfg_mask_temp) {
                    serial_send_bytes_shifted(0xE0, 0x00, 0x00, byte);
                    // TODO wait
                } else {
                    serial_send_byte(0xf8);
                    // TODO wait
                }

                cfg_mask_temp >>= 1;
                if (!cfg_mask_temp) {
                    stop_programming();

                    digitalWrite(PIC_STATUS, HIGH);
                    state = STATE_READY;
                    buf_at = 0;
                }
                break;
        }
    }
}
