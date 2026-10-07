CREATE DATABASE bazar_temtudo;
USE bazar_temtudo;

CREATE TABLE Carga (
    order_id VARCHAR(50), order_item_id VARCHAR(50),
    purchase_date DATETIME, payments_date DATETIME,
    buyer_email VARCHAR(100), buyer_name VARCHAR(100),
    cpf VARCHAR(20), buyer_phone_number VARCHAR(20),
    sku VARCHAR(50), product_name VARCHAR(100),
    quantity_purchased INT, currency VARCHAR(10),
    item_price DECIMAL(10,2), ship_service_level VARCHAR(50),
    recipient_name VARCHAR(100), ship_address_1 VARCHAR(150),
    ship_address_2 VARCHAR(150), ship_address_3 VARCHAR(150),
    ship_city VARCHAR(50), ship_state VARCHAR(50),
    ship_postal_code VARCHAR(20), ship_country VARCHAR(50),
    ioss_number VARCHAR(50)
);

CREATE TABLE CargaFornecedor (sku VARCHAR(50), quantidade_recebida INT);

CREATE TABLE Clientes (
    id INT AUTO_INCREMENT PRIMARY KEY,
    cpf VARCHAR(20) NOT NULL,
    nome VARCHAR(100), email VARCHAR(100), telefone VARCHAR(20),
    UNIQUE KEY uk_clientes_cpf (cpf)
);

CREATE TABLE Produtos (
    sku VARCHAR(50) PRIMARY KEY,
    nome VARCHAR(100), preco DECIMAL(10,2), estoque_atual INT DEFAULT 0
);

CREATE TABLE Pedidos (
    id_pedido VARCHAR(50) PRIMARY KEY,
    cpf_cliente VARCHAR(20),
    data_compra DATETIME,
    status_atendimento VARCHAR(30) DEFAULT 'PENDENTE',
    FOREIGN KEY (cpf_cliente) REFERENCES Clientes(cpf)
);

CREATE TABLE ItensPedido (
    id_pedido VARCHAR(50), id_item VARCHAR(50),
    sku VARCHAR(50), quantidade INT, preco_unitario DECIMAL(10,2),
    PRIMARY KEY (id_pedido, id_item),
    FOREIGN KEY (id_pedido) REFERENCES Pedidos(id_pedido),
    FOREIGN KEY (sku) REFERENCES Produtos(sku)
);

CREATE TABLE MovimentacaoEstoque (
    id INT AUTO_INCREMENT PRIMARY KEY,
    id_pedido VARCHAR(50) NULL,
    sku VARCHAR(50), quantidade INT, tipo VARCHAR(10),
    data_movimento DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE Compras (
    id INT AUTO_INCREMENT PRIMARY KEY,
    id_pedido VARCHAR(50), sku VARCHAR(50),
    quantidade_necessaria INT, status VARCHAR(20) DEFAULT 'PENDENTE'
);

DELIMITER $$

CREATE PROCEDURE Separar_Dados_Carga()
BEGIN
    DECLARE v_order_id VARCHAR(50);
    DECLARE v_order_item_id VARCHAR(50);
    DECLARE v_cpf VARCHAR(20);
    DECLARE v_sku VARCHAR(50);
    DECLARE v_buyer_name VARCHAR(100);
    DECLARE v_buyer_email VARCHAR(100);
    DECLARE v_buyer_phone_number VARCHAR(20);
    DECLARE v_purchase_date DATETIME;
    DECLARE v_product_name VARCHAR(100);
    DECLARE v_quantity_purchased INT;
    DECLARE v_item_price DECIMAL(10,2);
    DECLARE fim_arquivo INT DEFAULT FALSE;

    DECLARE cursor_carga CURSOR FOR
        SELECT order_id, order_item_id, purchase_date, buyer_email, buyer_name,
               cpf, buyer_phone_number, sku, product_name, quantity_purchased, item_price
        FROM Carga;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET fim_arquivo = TRUE;

    OPEN cursor_carga;

    meu_loop: LOOP
        FETCH cursor_carga INTO v_order_id, v_order_item_id, v_purchase_date, v_buyer_email,
            v_buyer_name, v_cpf, v_buyer_phone_number, v_sku, v_product_name,
            v_quantity_purchased, v_item_price;

        IF fim_arquivo THEN LEAVE meu_loop; END IF;

        SET v_cpf = NULLIF(TRIM(v_cpf), '');

        IF v_cpf IS NOT NULL THEN
            INSERT IGNORE INTO Clientes (cpf, nome, email, telefone)
            VALUES (v_cpf, v_buyer_name, v_buyer_email, v_buyer_phone_number);

            INSERT IGNORE INTO Produtos (sku, nome, preco, estoque_atual)
            VALUES (v_sku, v_product_name, v_item_price, 0);

            INSERT IGNORE INTO Pedidos (id_pedido, cpf_cliente, data_compra)
            VALUES (v_order_id, v_cpf, v_purchase_date);

            INSERT IGNORE INTO ItensPedido (id_pedido, id_item, sku, quantidade, preco_unitario)
            VALUES (v_order_id, v_order_item_id, v_sku, v_quantity_purchased, v_item_price);
        END IF;
    END LOOP;

    CLOSE cursor_carga;
    DELETE FROM Carga WHERE cpf IS NOT NULL AND TRIM(cpf) <> '';
END $$

CREATE PROCEDURE Processar_Estoque()
BEGIN
    DECLARE v_id_pedido VARCHAR(50);
    DECLARE v_itens_em_falta INT;
    DECLARE fim_pedidos INT DEFAULT FALSE;

    DECLARE cursor_pedidos CURSOR FOR
        SELECT p.id_pedido FROM Pedidos p
        JOIN ItensPedido i ON p.id_pedido = i.id_pedido
        WHERE p.status_atendimento IN ('PENDENTE', 'AGUARDANDO COMPRA')
        GROUP BY p.id_pedido
        ORDER BY SUM(i.quantidade * i.preco_unitario) DESC;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET fim_pedidos = TRUE;

    OPEN cursor_pedidos;

    loop_pedidos: LOOP
        FETCH cursor_pedidos INTO v_id_pedido;
        IF fim_pedidos THEN LEAVE loop_pedidos; END IF;

        SELECT COUNT(*) INTO v_itens_em_falta
        FROM ItensPedido i JOIN Produtos pr ON i.sku = pr.sku
        WHERE i.id_pedido = v_id_pedido AND pr.estoque_atual < i.quantidade;

        IF v_itens_em_falta = 0 THEN
            UPDATE Produtos pr JOIN ItensPedido i ON pr.sku = i.sku
            SET pr.estoque_atual = pr.estoque_atual - i.quantidade
            WHERE i.id_pedido = v_id_pedido;

            INSERT INTO MovimentacaoEstoque (id_pedido, sku, quantidade, tipo)
            SELECT id_pedido, sku, quantidade, 'SAIDA'
            FROM ItensPedido WHERE id_pedido = v_id_pedido;

            UPDATE Pedidos SET status_atendimento = 'ATENDIDO' WHERE id_pedido = v_id_pedido;
        else
            INSERT INTO Compras (id_pedido, sku, quantidade_necessaria)
            SELECT i.id_pedido, i.sku, i.quantidade - pr.estoque_atual
            FROM ItensPedido i JOIN Produtos pr ON i.sku = pr.sku
            WHERE i.id_pedido = v_id_pedido AND pr.estoque_atual < i.quantidade
            AND NOT EXISTS (SELECT 1 FROM Compras c
                            WHERE c.id_pedido = i.id_pedido AND c.sku = i.sku AND c.status = 'PENDENTE');

            UPDATE Pedidos SET status_atendimento = 'AGUARDANDO COMPRA' WHERE id_pedido = v_id_pedido;
        END IF;
    END LOOP;

    CLOSE cursor_pedidos;
END $$

CREATE PROCEDURE Atualizar_Estoque_Fornecedor(IN caminho VARCHAR(255))
BEGIN
    SET @comando = CONCAT('LOAD DATA INFILE "', caminho, '" INTO TABLE CargaFornecedor FIELDS TERMINATED BY ","');

    PREPARE cmd FROM @comando;
    EXECUTE cmd;
    DEALLOCATE PREPARE cmd;

    UPDATE Produtos p JOIN CargaFornecedor cf ON p.sku = cf.sku
    SET p.estoque_atual = p.estoque_atual + cf.quantidade_recebida;

    INSERT INTO MovimentacaoEstoque (sku, quantidade, tipo)
    SELECT sku, quantidade_recebida, 'ENTRADA' FROM CargaFornecedor;

    UPDATE Compras c JOIN CargaFornecedor cf ON c.sku = cf.sku
    SET c.status = 'RECEBIDO'
    WHERE c.status = 'PENDENTE';

    TRUNCATE TABLE CargaFornecedor;

    CALL Processar_Estoque();
END $$

CREATE PROCEDURE Importar_Marketplace(IN caminho VARCHAR(255))
BEGIN
    SET @comando = CONCAT('LOAD DATA INFILE "', caminho, '" INTO TABLE Carga FIELDS TERMINATED BY "," OPTIONALLY ENCLOSED BY ''"''');

    PREPARE cmd FROM @comando;
    EXECUTE cmd;
    DEALLOCATE PREPARE cmd;

    CALL Separar_Dados_Carga();
    CALL Processar_Estoque();
END $$

DELIMITER ;
