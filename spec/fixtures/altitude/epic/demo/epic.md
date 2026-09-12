### [~] `ledger` a ledger totals its entries

Blocks: `report`

```gherkin
Scenario: a ledger totals its entries
  Given a ledger of 2 and 3
  When its total is asked for
  Then it is 5
```

### [~] `report` a report renders the ledger's total

```gherkin
Scenario: a report renders the ledger's total
  Given a ledger of 2 and 3
  When it is reported
  Then the report reads "total: 5"

Scenario: a report's header counts the entries
  Given a ledger of 2 and 3
  When it is reported
  Then the report's header reads "entries: 2"
```
