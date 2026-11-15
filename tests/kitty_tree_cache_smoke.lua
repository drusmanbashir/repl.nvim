local sock = "unix:" .. vim.env.KITTY_TREE_TEST_SOCKET
local kt = require("repl.kitty_tree")
local failed = false
local function check(label, got, want)
  if got ~= want then
    print(("FAIL %s: got %s want %s"):format(label, vim.inspect(got), vim.inspect(want)))
    failed = true
  end
end

kt._test_reset()

-- 1. cold read reaches the socket; repeats do not
local tree = kt.get(sock)
check("cold read returns a tree", type(tree), "table")
check("two windows on the socket", #kt.windows(tree), 2)
for _ = 1, 4 do
  kt.get(sock)
end
local s = kt._test_stats()
check("one fetch for five reads", s.socket, 1)
check("four cache hits", s.hits, 4)
check("never fell back to the kitty CLI", s.cli, 0)

-- 2. a known window resolves without a fetch
kt._test_reset()
kt.get(sock)
local window = kt.window(sock, 2)
check("window 2 resolves", window and window.title, "dl-repl-1")
check("no refetch for a hit", kt._test_stats().socket, 1)

-- 3. an unknown id forces exactly one refresh before reporting it missing
kt._test_reset()
kt.get(sock)
local missing, err = kt.window(sock, 4242)
check("unknown window is nil", missing, nil)
check("miss is reported", type(err), "string")
check("exactly one forced refresh", kt._test_stats().refreshes, 1)
check("refresh actually refetched", kt._test_stats().socket, 2)

-- 4. invalidate drops the entry; fresh always refetches
kt._test_reset()
kt.get(sock)
kt.invalidate(sock)
kt.get(sock)
check("invalidate forces a refetch", kt._test_stats().socket, 2)
kt.fresh(sock)
check("fresh never reads the cache", kt._test_stats().socket, 3)

-- 5. TTL expiry refetches
kt._test_reset()
kt.get(sock, { ttl_ms = 0 })
kt.get(sock, { ttl_ms = 0 })
check("zero TTL always refetches", kt._test_stats().socket, 2)

-- 6. a socket that does not exist fails without throwing
local bad, bad_err = kt.get("unix:" .. vim.env.KITTY_TREE_TEST_SOCKET .. ".missing")
check("dead socket returns nil", bad, nil)
check("dead socket explains itself", type(bad_err), "string")

if not failed then
  print("OK all kitty_tree cache assertions")
end
