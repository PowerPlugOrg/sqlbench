-- RDBMS Benchmark Setup Script
-- Creates database, tables, and seed data for SQLQueryStress testing

USE master;
GO

-- Drop if exists and recreate
IF EXISTS (SELECT name FROM sys.databases WHERE name = 'BenchmarkTest')
BEGIN
    ALTER DATABASE BenchmarkTest SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BenchmarkTest;
END
GO

CREATE DATABASE BenchmarkTest;
GO

USE BenchmarkTest;
GO

-- Main test table for OLTP workload
CREATE TABLE TestTable (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Data NVARCHAR(100) NOT NULL,
    Value INT NOT NULL,
    Category TINYINT NOT NULL,
    Created DATETIME NOT NULL DEFAULT GETDATE()
);
GO

-- Secondary table for join tests
CREATE TABLE Categories (
    Id TINYINT PRIMARY KEY,
    Name NVARCHAR(50) NOT NULL,
    Description NVARCHAR(200)
);
GO

-- Accounts table for transaction tests
CREATE TABLE Accounts (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    AccountNumber NVARCHAR(20) NOT NULL UNIQUE,
    Balance DECIMAL(18,2) NOT NULL DEFAULT 0,
    LastUpdated DATETIME NOT NULL DEFAULT GETDATE()
);
GO

-- Create indexes
CREATE INDEX IX_TestTable_Value ON TestTable(Value);
CREATE INDEX IX_TestTable_Category ON TestTable(Category);
CREATE INDEX IX_TestTable_Created ON TestTable(Created);
GO

-- Seed categories
INSERT INTO Categories (Id, Name, Description) VALUES
(1, 'Electronics', 'Electronic devices and accessories'),
(2, 'Clothing', 'Apparel and fashion items'),
(3, 'Food', 'Food and beverages'),
(4, 'Books', 'Books and publications'),
(5, 'Home', 'Home and garden items');
GO

-- Seed initial test data (10,000 rows)
SET NOCOUNT ON;
DECLARE @i INT = 1;
WHILE @i <= 10000
BEGIN
    INSERT INTO TestTable (Data, Value, Category)
    VALUES (
        CAST(NEWID() AS NVARCHAR(100)),
        ABS(CHECKSUM(NEWID())) % 10000,
        (ABS(CHECKSUM(NEWID())) % 5) + 1
    );
    SET @i = @i + 1;
END
GO

-- Seed accounts (1,000 accounts with random balances)
DECLARE @j INT = 1;
WHILE @j <= 1000
BEGIN
    INSERT INTO Accounts (AccountNumber, Balance)
    VALUES (
        'ACC' + RIGHT('000000' + CAST(@j AS NVARCHAR(10)), 6),
        CAST(ABS(CHECKSUM(NEWID())) % 100000 AS DECIMAL(18,2))
    );
    SET @j = @j + 1;
END
GO

SET NOCOUNT OFF;

-- Verify setup
SELECT 'TestTable' AS TableName, COUNT(*) AS RowCount FROM TestTable
UNION ALL
SELECT 'Categories', COUNT(*) FROM Categories
UNION ALL
SELECT 'Accounts', COUNT(*) FROM Accounts;
GO

PRINT 'Benchmark database setup complete!';
GO
