-- Criação do banco de dados
CREATE DATABASE IF NOT EXISTS FintechDB;
USE FintechDB;

-- Tabela Cliente
CREATE TABLE cliente (
    id_cliente INT PRIMARY KEY AUTO_INCREMENT,
    nome VARCHAR(255) NOT NULL,
    cpf VARCHAR(11) UNIQUE NOT NULL,
    telefone VARCHAR(255),
    senha VARCHAR(255) NOT NULL,
    data_criacao DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Tabela Endereço
CREATE TABLE endereco (
    id INT PRIMARY KEY AUTO_INCREMENT,
    numero INT NOT NULL,
    bairro VARCHAR(255) NOT NULL,
    rua VARCHAR(255) NOT NULL,
    cliente_id INT,
    FOREIGN KEY (cliente_id) REFERENCES cliente(id_cliente) ON DELETE CASCADE
);

-- Tabela Conta
CREATE TABLE contas (
    id INT PRIMARY KEY AUTO_INCREMENT,
    id_cliente INT NOT NULL,
    tipo_conta ENUM('corrente', 'poupanca') NOT NULL,
    saldo DECIMAL(15, 2) DEFAULT 0.00,
    data_abertura DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (id_cliente) REFERENCES cliente(id_cliente) ON DELETE CASCADE
);

-- Tabela Cartão de Crédito
CREATE TABLE cartao_credito (
    cartao_id INT PRIMARY KEY AUTO_INCREMENT,
    cliente_id INT NOT NULL,
    limite DECIMAL(15, 2) NOT NULL,
    saldo_fatura DECIMAL(15, 2) DEFAULT 0.00,
    data_emissao DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (cliente_id) REFERENCES cliente(id_cliente) ON DELETE CASCADE
);

-- Tabela Empréstimo
CREATE TABLE emprestimo (
    emprestimo_id INT PRIMARY KEY AUTO_INCREMENT,
    cliente_id INT NOT NULL,
    valor DECIMAL(15, 2) NOT NULL,
    taxa_juros DECIMAL(5, 2) NOT NULL,
    data_contratacao DATETIME DEFAULT CURRENT_TIMESTAMP,
    data_vencimento DATETIME NOT NULL,
    FOREIGN KEY (cliente_id) REFERENCES cliente(id_cliente) ON DELETE CASCADE
);

-- Tabela Transação
CREATE TABLE transacao (
    transacao_id INT PRIMARY KEY AUTO_INCREMENT,
    conta_id INT NOT NULL,
    tipo_transacao ENUM('deposito', 'saque', 'transferencia') NOT NULL,
    valor DECIMAL(15, 2) NOT NULL,
    data_transacao DATETIME DEFAULT CURRENT_TIMESTAMP,
    descricao VARCHAR(255),
    FOREIGN KEY (conta_id) REFERENCES contas(id) ON DELETE CASCADE
);

-- Tabela Extrato
CREATE TABLE extrato (
    extrato_id INT PRIMARY KEY AUTO_INCREMENT,
    conta_id INT NOT NULL,
    data_extrato DATETIME DEFAULT CURRENT_TIMESTAMP,
    transacoes JSON,
    FOREIGN KEY (conta_id) REFERENCES contas(id) ON DELETE CASCADE
);

------------- TRIGGERS --------------

DELIMITER $$
-- Trigger para garantir que o saldo do cartão de crédito não exceda o limite em compras
CREATE TRIGGER trg_cartao_limite_prevent
BEFORE INSERT ON transacao
FOR EACH ROW
BEGIN
    -- Verificar se a transação é uma compra de crédito
    IF NEW.tipo_transacao = 'compra_credito' THEN
        -- Definir a variável limite_cartao e saldo_atual com SET
        SET @limite_cartao = (SELECT limite FROM cartao_credito WHERE cartao_id = NEW.conta_id);
        SET @saldo_fatura = (SELECT saldo_fatura FROM cartao_credito WHERE cartao_id = NEW.conta_id);
        
        -- Verificar se o valor da compra ultrapassa o limite disponível
        IF @saldo_fatura + NEW.valor > @limite_cartao THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Limite de crédito insuficiente para essa compra.';
        END IF;
    END IF;
END $$
DELIMITER ;


-- Trigger para atualizar saldo da fatura de cartão após uma compra ou pagamento
DELIMITER $$
CREATE TRIGGER trg_atualiza_saldo_fatura
AFTER INSERT ON transacao
FOR EACH ROW
BEGIN
    IF NEW.tipo_transacao = 'compra_credito' THEN
        UPDATE cartao_credito SET saldo_fatura = saldo_fatura + NEW.valor WHERE cartao_id = NEW.conta_id;
    ELSEIF NEW.tipo_transacao = 'pagamento_fatura' THEN
        UPDATE cartao_credito SET saldo_fatura = saldo_fatura - NEW.valor WHERE cartao_id = NEW.conta_id;
    END IF;
END $$;
DELIMITER ;

DELIMITER $$
-- Trigger para garantir que o saldo não fique negativo em transações de saque
CREATE TRIGGER trg_saque_prevent
BEFORE INSERT ON transacao
FOR EACH ROW
BEGIN
    IF NEW.tipo_transacao = 'saque' OR NEW.tipo_transacao = 'transferencia' THEN
        -- Usar variável de sessão em vez de DECLARE
        SET @saldo_atual = (SELECT saldo FROM contas WHERE id = NEW.conta_id);
        
        IF @saldo_atual < NEW.valor THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Saldo insuficiente para essa transação.';
        END IF;
    END IF;
END $$
DELIMITER ;

DELIMITER $$
-- Trigger para atualizar o saldo da conta após uma transação
CREATE TRIGGER trg_atualiza_saldo
AFTER INSERT ON transacao
FOR EACH ROW
BEGIN
    IF NEW.tipo_transacao = 'deposito' THEN
        UPDATE contas SET saldo = saldo + NEW.valor WHERE id = NEW.conta_id;
    ELSEIF NEW.tipo_transacao = 'saque' OR NEW.tipo_transacao = 'transferencia' THEN
        UPDATE contas SET saldo = saldo - NEW.valor WHERE id = NEW.conta_id;
    END IF;
END $$
DELIMITER ;

----------------- PROCEDURES ---------------------

-- Procedure para transferência entre contas
DELIMITER $$
CREATE PROCEDURE Transferencia(IN p_conta_origem INT, IN p_conta_destino INT, IN p_valor DECIMAL(15, 2))
BEGIN
    DECLARE saldo_origem DECIMAL(15, 2);

    -- Verificar saldo da conta de origem
    SET saldo_origem = (SELECT saldo FROM contas WHERE id = p_conta_origem);
    IF saldo_origem < p_valor THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Saldo insuficiente para realizar a transferência.';
    ELSE
        -- Iniciar transação
        START TRANSACTION;

        -- Debitar da conta de origem
        INSERT INTO transacao (conta_id, tipo_transacao, valor, descricao) VALUES (p_conta_origem, 'transferencia', p_valor, 'Transferência para conta destino');
        
        -- Creditar na conta de destino
        INSERT INTO transacao (conta_id, tipo_transacao, valor, descricao) VALUES (p_conta_destino, 'deposito', p_valor, 'Transferência recebida da conta origem');

        -- Confirmar transação
        COMMIT;
    END IF;
END$$
DELIMITER ;

-- Procedure para pagamento de fatura de cartão de crédito
DELIMITER $$
CREATE PROCEDURE PagarFatura(IN p_cartao_id INT, IN p_valor DECIMAL(15, 2))
BEGIN
    DECLARE saldo_conta DECIMAL(15, 2);

    -- Verificar saldo na conta associada para pagamento
    SET saldo_conta = (SELECT saldo FROM contas WHERE id = (SELECT cliente_id FROM cartao_credito WHERE cartao_id = p_cartao_id));
    IF saldo_conta < p_valor THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Saldo insuficiente na conta para pagamento da fatura.';
    ELSE
        -- Iniciar transação
        START TRANSACTION;

        -- Debitar o valor da conta associada
        INSERT INTO transacao (conta_id, tipo_transacao, valor, descricao) VALUES ((SELECT cliente_id FROM cartao_credito WHERE cartao_id = p_cartao_id), 'saque', p_valor, 'Pagamento de fatura');
        
        -- Atualizar saldo da fatura do cartão
        INSERT INTO transacao (conta_id, tipo_transacao, valor, descricao) VALUES (p_cartao_id, 'pagamento_fatura', p_valor, 'Pagamento da fatura do cartão de crédito');

        -- Confirmar transação
        COMMIT;
    END IF;
END$$
DELIMITER ;

DELIMITER $$
CREATE PROCEDURE CriarEmprestimo(IN p_cliente_id INT, IN p_valor DECIMAL(15, 2), IN p_taxa_juros DECIMAL(5, 2), IN p_data_vencimento DATETIME)
BEGIN
    DECLARE saldo_conta DECIMAL(15, 2);
    DECLARE valor_com_juros DECIMAL(15, 2);

    -- Calcular valor final com juros
    SET valor_com_juros = p_valor * (1 + (p_taxa_juros / 100));

    -- Registrar empréstimo
    INSERT INTO emprestimo (cliente_id, valor, taxa_juros, data_contratacao, data_vencimento)
    VALUES (p_cliente_id, valor_com_juros, p_taxa_juros, CURRENT_TIMESTAMP, p_data_vencimento);

    -- Crédito inicial na conta do cliente
    SET saldo_conta = (SELECT saldo FROM contas WHERE id_cliente = p_cliente_id);
    INSERT INTO transacao (conta_id, tipo_transacao, valor, descricao) VALUES ((SELECT id FROM contas WHERE id_cliente = p_cliente_id), 'deposito', p_valor, 'Crédito de empréstimo');
END$$
DELIMITER ;

DELIMITER $$
CREATE PROCEDURE GerarExtrato(IN p_conta_id INT)
BEGIN
    DECLARE transacoes JSON;
    
    -- Obter todas as transações da conta e armazenar em JSON
    SET transacoes = (SELECT JSON_ARRAYAGG(JSON_OBJECT('id', transacao_id, 'tipo', tipo_transacao, 'valor', valor, 'data', data_transacao, 'descricao', descricao)) 
                      FROM transacao WHERE conta_id = p_conta_id);
    
    -- Inserir o extrato na tabela extrato
    INSERT INTO extrato (conta_id, data_extrato, transacoes) VALUES (p_conta_id, CURRENT_TIMESTAMP, transacoes);
END$$
DELIMITER ;

DELIMITER $$
CREATE PROCEDURE ConsultarSaldo(IN p_conta_id INT)
BEGIN
    DECLARE saldo_atual DECIMAL(15, 2);

    -- Obter saldo atual da conta
    SELECT saldo INTO saldo_atual FROM contas WHERE id = p_conta_id;

    -- Retornar saldo
    SELECT saldo_atual AS SaldoAtual;
END $$
DELIMITER ;

DELIMITER $$

CREATE PROCEDURE GerarExtrato(IN p_conta_id INT)
BEGIN
    -- Seleciona todas as transações relacionadas à conta específica
    SELECT transacao_id, tipo_transacao, valor, data_transacao, descricao
    FROM transacao
    WHERE conta_id = p_conta_id
    ORDER BY data_transacao;
END $$

DELIMITER ;

DELIMITER $$

CREATE PROCEDURE PagarFaturaCartao(IN p_conta_id INT, IN p_cartao_id INT, IN p_valor DECIMAL(15, 2))
BEGIN
    DECLARE saldo_conta DECIMAL(15, 2);
    DECLARE saldo_fatura DECIMAL(15, 2);

    -- Obter saldo da conta e saldo da fatura
    SET saldo_conta = (SELECT saldo FROM contas WHERE id = p_conta_id);
    SET saldo_fatura = (SELECT saldo_fatura FROM cartao_credito WHERE cartao_id = p_cartao_id);

    -- Verificar se o saldo da conta é suficiente para cobrir o valor do pagamento
    IF saldo_conta < p_valor THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Saldo insuficiente na conta para pagar a fatura do cartão de crédito.';
    ELSEIF saldo_fatura < p_valor THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'O valor excede o saldo da fatura do cartão de crédito.';
    ELSE
        -- Iniciar transação
        START TRANSACTION;

        -- Deduzir o valor da fatura do cartão de crédito
        UPDATE cartao_credito SET saldo_fatura = saldo_fatura - p_valor WHERE cartao_id = p_cartao_id;

        -- Deduzir o valor do saldo da conta
        UPDATE contas SET saldo = saldo - p_valor WHERE id = p_conta_id;

        -- Inserir transação de pagamento de fatura
        INSERT INTO transacao (conta_id, tipo_transacao, valor, descricao) 
        VALUES (p_conta_id, 'pagamento_fatura', p_valor, 'Pagamento de fatura do cartão de crédito');

        -- Confirmar transação
        COMMIT;
    END IF;
END $$

DELIMITER ;

DELIMITER $$

CREATE PROCEDURE AtualizarJurosEmprestimo(IN p_emprestimo_id INT)
BEGIN
    DECLARE valor_emprestimo DECIMAL(15, 2);
    DECLARE taxa_juros DECIMAL(5, 2);
    DECLARE juros_acumulados DECIMAL(15, 2);

    -- Obter o valor do empréstimo e a taxa de juros
    SET valor_emprestimo = (SELECT valor FROM emprestimo WHERE emprestimo_id = p_emprestimo_id);
    SET taxa_juros = (SELECT taxa_juros FROM emprestimo WHERE emprestimo_id = p_emprestimo_id);

    -- Calcular juros acumulados (simples neste exemplo)
    SET juros_acumulados = valor_emprestimo * (taxa_juros / 100);

    -- Atualizar o valor do empréstimo com os juros acumulados
    UPDATE emprestimo SET valor = valor + juros_acumulados WHERE emprestimo_id = p_emprestimo_id;

    -- Inserir transação de atualização de juros (opcional para histórico)
    INSERT INTO transacao (conta_id, tipo_transacao, valor, descricao) 
    VALUES (NULL, 'atualizacao_juros', juros_acumulados, 'Atualização de juros sobre empréstimo');
END $$

DELIMITER ;

-- Configuração de nível de isolamento para evitar problemas de concorrência
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;