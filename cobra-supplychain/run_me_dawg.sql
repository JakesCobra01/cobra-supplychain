CREATE TABLE IF NOT EXISTS `orders` (
  `id`            int(11)                                NOT NULL AUTO_INCREMENT,
  `owner_id`      int(11)                                DEFAULT NULL,
  `ingredient`    varchar(255)                           DEFAULT NULL,
  `quantity`      int(11)                                DEFAULT NULL,
  `status`        enum('pending','accepted','completed') DEFAULT 'pending',
  `created_at`    timestamp                              NOT NULL DEFAULT current_timestamp(),
  `restaurant_id` int(11)                                NOT NULL DEFAULT 1,
  `total_cost`    decimal(10,2)                          DEFAULT NULL,
  `batch_id`      varchar(36)                            DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_batch_id`          (`batch_id`),
  KEY `idx_status`             (`status`),
  KEY `idx_restaurant_status` (`restaurant_id`, `status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

CREATE TABLE IF NOT EXISTS `stock` (
  `id`            int(11)      NOT NULL AUTO_INCREMENT,
  `restaurant_id` int(11)      DEFAULT NULL,
  `ingredient`    varchar(255) DEFAULT NULL,
  `quantity`      int(11)      DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_restaurant_ingredient` (`restaurant_id`, `ingredient`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

CREATE TABLE IF NOT EXISTS `warehouse_stock` (
  `id`         int(11)      NOT NULL AUTO_INCREMENT,
  `ingredient` varchar(255) DEFAULT NULL,
  `quantity`   int(11)      DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_ingredient` (`ingredient`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;