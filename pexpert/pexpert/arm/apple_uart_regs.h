/*
 * Copyright (c) 2000-2020 Apple Inc. All rights reserved.
 */
#ifndef _PEXPERT_ARM_APPLE_UART_REGS_H
#define _PEXPERT_ARM_APPLE_UART_REGS_H

#define APPLE_UART

// UART
#define rULCON0     (*(volatile unsigned *)(uart_base + 0x00)) // UART 0 Line control
#define rUCON0      (*(volatile unsigned *)(uart_base + 0x04)) // UART 0 Control
#define rUFCON0     (*(volatile unsigned *)(uart_base + 0x08)) // UART 0 FIFO control
#define rUMCON0     (*(volatile unsigned *)(uart_base + 0x0c)) // UART 0 Modem control
#define rUTRSTAT0   (*(volatile unsigned *)(uart_base + 0x10)) // UART 0 Tx/Rx status
#define rUERSTAT0   (*(volatile unsigned *)(uart_base + 0x14)) // UART 0 Rx error status
#define rUFSTAT0    (*(volatile unsigned *)(uart_base + 0x18)) // UART 0 FIFO status
#define rUMSTAT0    (*(volatile unsigned *)(uart_base + 0x1c)) // UART 0 Modem status
#define rUTXH0      (*(volatile unsigned *)(uart_base + 0x20)) // UART 0 Transmission Hold
#define rURXH0      (*(volatile unsigned *)(uart_base + 0x24)) // UART 0 Receive buffer
#define rUBRDIV0    (*(volatile unsigned *)(uart_base + 0x28)) // UART 0 Baud rate divisor
#define rUDIVSLOT0  (*(volatile unsigned *)(uart_base + 0x2C)) // UART 0 Baud rate divisor

#define rULCON1     (*(volatile unsigned *)(uart1_base + 0x00)) // UART 1 Line control
#define rUCON1      (*(volatile unsigned *)(uart1_base + 0x04)) // UART 1 Control
#define rUFCON1     (*(volatile unsigned *)(uart1_base + 0x08)) // UART 1 FIFO control
#define rUMCON1     (*(volatile unsigned *)(uart1_base + 0x0c)) // UART 1 Modem control
#define rUTRSTAT1   (*(volatile unsigned *)(uart1_base + 0x10)) // UART 1 Tx/Rx status
#define rUERSTAT1   (*(volatile unsigned *)(uart1_base + 0x14)) // UART 1 Rx error status
#define rUFSTAT1    (*(volatile unsigned *)(uart1_base + 0x18)) // UART 1 FIFO status
#define rUMSTAT1    (*(volatile unsigned *)(uart1_base + 0x1c)) // UART 1 Modem status
#define rUTXH1      (*(volatile unsigned *)(uart1_base + 0x20)) // UART 1 Transmission Hold
#define rURXH1      (*(volatile unsigned *)(uart1_base + 0x24)) // UART 1 Receive buffer
#define rUBRDIV1    (*(volatile unsigned *)(uart1_base + 0x28)) // UART 1 Baud rate divisor

#define rULCON2     (*(volatile unsigned *)(uart2_base + 0x00)) // UART 2 Line control
#define rUCON2      (*(volatile unsigned *)(uart2_base + 0x04)) // UART 2 Control
#define rUFCON2     (*(volatile unsigned *)(uart2_base + 0x08)) // UART 2 FIFO control
#define rUMCON2     (*(volatile unsigned *)(uart2_base + 0x0c)) // UART 2 Modem control
#define rUTRSTAT2   (*(volatile unsigned *)(uart2_base + 0x10)) // UART 2 Tx/Rx status
#define rUERSTAT2   (*(volatile unsigned *)(uart2_base + 0x14)) // UART 2 Rx error status
#define rUFSTAT2    (*(volatile unsigned *)(uart2_base + 0x18)) // UART 2 FIFO status
#define rUMSTAT2    (*(volatile unsigned *)(uart2_base + 0x1c)) // UART 2 Modem status
#define rUTXH2      (*(volatile unsigned *)(uart2_base + 0x20)) // UART 2 Transmission Hold
#define rURXH2      (*(volatile unsigned *)(uart2_base + 0x24)) // UART 2 Receive buffer
#define rUBRDIV2    (*(volatile unsigned *)(uart2_base + 0x28)) // UART 2 Baud rate divisor

#endif /* _PEXPERT_ARM_APPLE_UART_REGS_H */
