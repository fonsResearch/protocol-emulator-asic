| scenario | verdict | stamp | board time - fault instant (cycles) | RTL = GL |
|---|---|---|---|---|
| calibrate | fail 13 lane 0 | 7236 |  | yes |
| i2c_ctl_clean | clean |  |  | yes |
| i2c_ctl_late_ack | blame 77 lane 0 | 39042 | 10 | yes |
| i2c_ctl_slow_target | blame 77 lane 0 | 43274 | 10 | yes |
| i2c_tgt_clean | clean |  |  | yes |
| i2c_tgt_short_start_hold | blame 82 lane 0 | 32122 | 4 | yes |
| spi_ctl_clean | clean |  |  | yes |
| spi_ctl_slow_target | blame 91 lane 1 | 7850 | 9 | yes |
| spi_tgt_clean | clean |  |  | yes |
| spi_tgt_early_cs | blame 52 lane 1 | 9810 | 12 | yes |
| two_lanes | clean |  |  | yes |
| uart_rx_clean | clean |  |  | yes |
| uart_rx_fast_peer | blame 32 lane 0 | 6995 | 969 | yes |
| uart_tx_bad_start | fail 13 lane 0 | 7236 |  | yes |
| uart_tx_clean | clean |  |  | yes |
| usb_ls_tx | clean |  |  | yes |
| windows_uart_d6 | clean |  |  | yes |

0 differing or missing records
