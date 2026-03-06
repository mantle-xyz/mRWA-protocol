// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum RequestStatus {
    NONE,
    PENDING,
    PROCESSING,
    READY,
    CLAIMED
}

enum InFlightStatus {
    NONE,
    PENDING,
    CONFIRMED
}
