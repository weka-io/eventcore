module eventcore.internal.utils;
void print(ARGS...)(string str, ARGS args)
@trusted @nogc nothrow {
	import std.format : formattedWrite;
	StdoutRange r;
	scope cb = () {
		scope (failure) assert(false);
		(&r).formattedWrite(str, args);
	};
	(cast(void delegate() @nogc @safe nothrow)cb)();
	r.put('\n');
}

struct StdoutRange {
	@safe: @nogc: nothrow:
	import core.stdc.stdio;

	void put(string str)
	{
		() @trusted { fwrite(str.ptr, str.length, 1, stdout); } ();
	}

	void put(char ch)
	{
		() @trusted { fputc(ch, stdout); } ();
	}
}

struct ChoppedVector(T, size_t CHUNK_SIZE = 16*64*1024/nextPOT(T.sizeof)) {
	static assert(nextPOT(CHUNK_SIZE) == CHUNK_SIZE,
		"CHUNK_SIZE must be a power of two for performance reasons.");

	@safe: @nogc: nothrow:
	import core.stdc.stdlib : calloc, free, malloc, realloc;
	import std.traits : hasElaborateDestructor;

	static assert(!hasElaborateDestructor!T);

	alias chunkSize = CHUNK_SIZE;

	private {
		alias Chunk = T[chunkSize];
		alias ChunkPtr = Chunk*;
		ChunkPtr[] m_chunks;
		size_t m_chunkCount;
		size_t m_length;
	}

	@disable this(this);

	~this()
	{
		clear();
	}

	@property size_t length() const { return m_length; }

	void clear()
	{
		() @trusted {
			foreach (i; 0 .. m_chunkCount)
				free(m_chunks[i]);
			free(m_chunks.ptr);
		} ();
		m_chunkCount = 0;
		m_length = 0;
	}

	ref T opIndex(size_t index)
	{
		auto chunk = index / chunkSize;
		auto subidx = index % chunkSize;
		if (index >= m_length) m_length = index+1;
		reserveChunk(chunk);
		return (*m_chunks[chunk])[subidx];
	}

	private void reserveChunk(size_t chunkidx)
	{
		if (m_chunks.length <= chunkidx) {
			auto l = m_chunks.length == 0 ? 64 : m_chunks.length;
			while (l <= chunkidx) l *= 2;
			() @trusted {
				auto newptr = cast(ChunkPtr*)realloc(m_chunks.ptr, l * ChunkPtr.length);
				m_chunks = newptr[0 .. l];
			} ();
		}

		while (m_chunkCount <= chunkidx) {
			() @trusted { m_chunks[m_chunkCount++] = cast(ChunkPtr)calloc(chunkSize, T.sizeof); } ();
		}
	}
}

private size_t nextPOT(size_t n)
{
	foreach_reverse (i; 0 .. size_t.sizeof*8) {
		size_t ni = cast(size_t)1 << i;
		if (n & ni) {
			return n & (ni-1) ? ni << 1 : ni;
		}
	}
	return 1;
}

unittest {
	assert(nextPOT(1) == 1);
	assert(nextPOT(2) == 2);
	assert(nextPOT(3) == 4);
	assert(nextPOT(4) == 4);
	assert(nextPOT(5) == 8);
}
