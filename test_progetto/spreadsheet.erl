-module(spreadsheet).
-author("daniros").

-record(cell, {id, row, column, value={primitive, undef}}).
-record(sheet_page, {name, cells_ids=[]}).
-record(sheet, {name, sheet_page_ids=[]}).


%% API
-export([init/0, start/0, populate_cell/2, create_cell/2]).


init() ->
  mnesia:create_schema([node()]),
  mnesia:start(),
  create_tables(),
  mnesia:stop()
.

create_tables() ->
  mnesia:create_table(cell, [{attributes, record_info(fields, cell)}]),
  mnesia:create_table(sheet_page, [{attributes, record_info(fields, sheet_page)}]),
  mnesia:create_table(sheet, [{attributes, record_info(fields, sheet)}])
.

start() ->
  mnesia:start(),
  mnesia:wait_for_tables([sheet,sheet_page,cell], 20000)
.

create_cell(NumRows, NumColumns) ->
  mnesia:transaction(fun() -> populate_cell(NumRows, NumColumns) end)
.

populate_cell(NumRows, NumColumns) ->
  Rows = lists:seq(1, NumRows),
  Columns = lists:seq(1, NumColumns),
  lists:foreach(
    fun(Row) ->
      lists:foreach(
        fun(Column) ->
          Cell = #cell{
            id = {Row, Column},
            row = Row,
            column = Column,
            value = "A"
          },
          mnesia:write(Cell)
        end,
        Columns)
    end,
    Rows)
.


%% CREZIONE CELLE OK, CREARE I TAB A CUI DEVO LEGARE IL RIFERIMENTO ALLE CELLE