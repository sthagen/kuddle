defmodule Kuddle.V1.Decoder do
  @moduledoc """
  Tokenizes and parses KDL documents into kuddle documents.
  """
  alias Kuddle.Value
  alias Kuddle.Node

  import Kuddle.Tokens
  import Kuddle.V1.Utils
  import Kuddle.V1.Tokenizer

  @typedoc """
  Parsed tokens from the Tokenizer, these will be processed and converted into the final nodes for
  the document.
  """
  @type tokens :: Kuddle.V1.Tokenizer.tokens()

  @typedoc """
  A single node in the Kuddle document
  """
  @type document_node :: Node.t()

  @typedoc """
  A kuddle document is a list of Kuddle Nodes
  """
  @type document :: [document_node()]

  @doc """
  Same as decode/1, but will raise a Kuddle.DecodeError on error from decode.
  """
  @spec decode!(String.t()) :: document()
  def decode!(blob) when is_binary(blob) do
    case decode(blob) do
      {:ok, tokens, _rest} ->
        tokens

      {:error, reason} ->
        raise Kuddle.DecodeError, reason: reason
    end
  end

  @doc """
  Tokenize and parse a given KDL document.

  If successful, it will return `{:ok, document, tokens}`, where document is the list of nodes that
  were parsed and tokens are any unparsed tokens.
  """
  @spec decode(String.t()) ::
    {:ok, document(), tokens()}
    | {:error, term()}
  def decode(blob) when is_binary(blob) do
    case tokenize(blob) do
      {:ok, tokens, ""} ->
        decode(tokens)

      {:error, _} = err ->
        err
    end
  end

  def decode(tokens) when is_list(tokens) do
    parse(tokens, {:default, 0}, [], [])
  end

  defp parse([], {:default, 0}, [], doc) do
    handle_parse_exit([], doc)
  end

  defp parse([r_annotation_token() = annotation | tokens], {:default, _} = state, acc, doc) do
    parse(tokens, state, [annotation | acc], doc)
  end

  defp parse([r_slashdash_token() | tokens], {:default, _} = state, acc, doc) do
    # add the slashdash to the document accumulator
    # when the next parse is done, the slashdash will cause the next item in the accumulator to
    # be dropped
    parse(tokens, state, acc, [:slashdash | doc])
  end

  defp parse([r_comment_token() | tokens], {:default, _} = state, acc, doc) do
    parse(tokens, state, acc, doc)
  end

  defp parse([r_fold_token() | tokens], {:default, _} = state, acc, doc) do
    parse(unfold_leading_tokens(tokens), state, acc, doc)
  end

  defp parse([r_semicolon_token() | tokens], {:default, _} = state, acc, doc) do
    # loose semi-colon
    parse(tokens, state, acc, doc)
  end

  defp parse([r_newline_token() | tokens], {:default, _} = state, acc, doc) do
    # trim leading newlines
    parse(tokens, state, acc, doc)
  end

  defp parse([r_space_token() | tokens], {:default, _} = state, acc, doc) do
    # trim leading space
    parse(tokens, state, acc, doc)
  end

  defp parse([r_term_token(value: name) | tokens], {:default, depth}, acc, doc) do
    # node
    annotations = extract_annotations(acc)
    parse(tokens, {:node, depth}, {name, annotations, []}, doc)
  end

  defp parse([r_dquote_string_token(value: name) | tokens], {:default, depth}, acc, doc) do
    # double quote initiated node
    annotations = extract_annotations(acc)
    parse(tokens, {:node, depth}, {name, annotations, []}, doc)
  end

  defp parse([r_raw_string_token(value: name) | tokens], {:default, depth}, acc, doc) do
    # raw string node
    annotations = extract_annotations(acc)
    parse(tokens, {:node, depth}, {name, annotations, []}, doc)
  end

  defp parse([r_slashdash_token() | tokens], {:node, _} = state, {name, annotations, attrs}, doc) do
    parse(tokens, state, {name, annotations, [:slashdash | attrs]}, doc)
  end

  defp parse([r_comment_token() | tokens], {:node, _} = state, acc, doc) do
    # trim comments
    parse(tokens, state, acc, doc)
  end

  defp parse([r_space_token() | tokens], {:node, _} = state, acc, doc) do
    # trim leading spaces in node
    parse(tokens, state, acc, doc)
  end

  defp parse([r_fold_token() | tokens], {:node, _} = state, acc, doc) do
    parse(unfold_leading_tokens(tokens), state, acc, doc)
  end

  defp parse(
    [{token_type, _value, _meta} | tokens],
    {:node, depth},
    {name, node_annotations, attrs},
    doc
  ) when token_type in [:nl, :sc] do
    node = %Node{
      name: name,
      annotations: node_annotations,
      attributes: resolve_node_attributes(attrs),
      children: nil,
    }
    parse(tokens, {:default, depth}, [], [node | doc])
  end

  defp parse([r_open_block_token() | tokens], {:node, depth}, {name, node_annotations, attrs}, doc) do
    case parse(tokens, {:default, depth + 1}, [], []) do
      {:ok, children, tokens} ->
        case trim_leading_space(tokens) do
          [r_close_block_token() | tokens] ->
            node =
              case attrs do
                [:slashdash | attrs] ->
                  # discard the children
                  %Node{
                    name: name,
                    annotations: node_annotations,
                    attributes: resolve_node_attributes(attrs),
                    children: nil,
                  }

                attrs ->
                  %Node{
                    name: name,
                    annotations: node_annotations,
                    attributes: resolve_node_attributes(attrs),
                    children: children,
                  }
              end

            parse(tokens, {:default, depth}, [], [node | doc])
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse([r_annotation_token() = annotation | tokens], {:node, _} = state, {name, node_annotations, attrs}, doc) do
    attrs = [annotation | attrs]
    parse(tokens, state, {name, node_annotations, attrs}, doc)
  end

  defp parse([token | tokens], {:node, _} = state, {name, node_annotations, attrs}, doc) do
    case token_to_value(token) do
      {:ok, %Value{} = key} ->
        {key_annotations, attrs} =
          case attrs do
            [r_annotation_token(value: annotation) | attrs] ->
              {[annotation], attrs}

            attrs ->
              {[], attrs}
          end

        key = %{key | annotations: key.annotations ++ key_annotations}

        case trim_leading_space(tokens) do
          [r_equal_token() | tokens] ->
            tokens = trim_leading_space(tokens)
            {value_annotations, tokens} =
              case tokens do
                [r_annotation_token(value: annotation) | tokens] ->
                  {[annotation], tokens}

                tokens ->
                  {[], tokens}
              end

            [token | tokens] = tokens
            case token_to_value(token) do
              {:ok, %Value{} = value} ->
                value = %{value | annotations: value.annotations ++ value_annotations}
                parse(tokens, state, {name, node_annotations, [{key, value} | attrs]}, doc)

              {:error, _} = err ->
                err
            end

          tokens ->
            case key do
              %{type: :id} ->
                {:error, {:bare_identifier, key}}

              _ ->
                parse(tokens, state, {name, node_annotations, [key | attrs]}, doc)
            end
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse([], {:node, depth}, {name, node_annotations, attrs}, doc) do
    node = %Node{
      name: name,
      annotations: node_annotations,
      attributes: resolve_node_attributes(attrs),
      children: nil,
    }
    parse([], {:default, depth}, [], [node | doc])
  end

  defp parse([r_close_block_token() | _tokens] = tokens, {:default, _depth}, [], doc) do
    handle_parse_exit(tokens, doc)
  end

  defp extract_annotations(items, acc \\ [])

  defp extract_annotations([], acc) do
    Enum.reverse(acc)
  end

  defp extract_annotations([r_annotation_token(value: value) | rest], acc) do
    extract_annotations(rest, [value | acc])
  end

  defp extract_annotations([_ | rest], acc) do
    extract_annotations(rest, acc)
  end

  defp handle_parse_exit(rest, doc) do
    doc = Enum.reverse(doc)

    {:ok, handle_slashdashes(doc, []), rest}
  end

  defp resolve_node_attributes(acc) do
    acc
    |> Enum.reverse()
    |> handle_slashdashes([])
    |> Enum.reduce([], fn
      {key, value}, acc ->
        # deduplicate attributes
        acc =
          Enum.reject(acc, fn
            {key2, _value} -> key2.value == key.value
            _ -> false
          end)

        [{key, value} | acc]

      value, acc ->
        [value | acc]
    end)
    |> Enum.reverse()
  end

  defp unfold_leading_tokens(tokens, remaining \\ 1)

  defp unfold_leading_tokens([r_space_token() | tokens], remaining) do
    unfold_leading_tokens(tokens, remaining)
  end

  defp unfold_leading_tokens([r_newline_token() | tokens], remaining) when remaining > 0 do
    unfold_leading_tokens(tokens, remaining - 1)
  end

  defp unfold_leading_tokens([r_comment_token() | tokens], remaining) when remaining > 0 do
    unfold_leading_tokens(tokens, remaining - 1)
  end

  defp unfold_leading_tokens(tokens, 0) do
    tokens
  end

  defp trim_leading_space(tokens, remaining \\ 0)

  defp trim_leading_space([r_space_token() | tokens], remaining) do
    trim_leading_space(tokens, remaining)
  end

  defp trim_leading_space([r_newline_token() | tokens], remaining) when remaining > 0 do
    trim_leading_space(tokens, remaining - 1)
  end

  defp trim_leading_space([r_comment_token() | tokens], remaining) when remaining > 0 do
    trim_leading_space(tokens, remaining - 1)
  end

  defp trim_leading_space([r_fold_token() | tokens], remaining) do
    trim_leading_space(tokens, remaining + 1)
  end

  defp trim_leading_space(tokens, 0) do
    tokens
  end

  defp token_to_value(r_term_token(value: value)) do
    decode_term(value)
  end

  defp token_to_value(r_dquote_string_token(value: value)) do
    {:ok, %Value{value: value, type: :string}}
  end

  defp token_to_value(r_raw_string_token(value: value)) do
    {:ok, %Value{value: value, type: :string}}
  end

  defp decode_term("true") do
    {:ok, %Value{value: true, type: :boolean}}
  end

  defp decode_term("false") do
    {:ok, %Value{value: false, type: :boolean}}
  end

  defp decode_term("null") do
    {:ok, %Value{type: :null, value: nil}}
  end

  defp decode_term(<<"0b", rest::binary>>) do
    decode_bin_integer(:_, rest)
  end

  defp decode_term(<<"+0b", rest::binary>>) do
    decode_bin_integer(:+, rest)
  end

  defp decode_term(<<"-0b", rest::binary>>) do
    decode_bin_integer(:-, rest)
  end

  defp decode_term(<<"0o", rest::binary>>) do
    decode_oct_integer(:_, rest)
  end

  defp decode_term(<<"+0o", rest::binary>>) do
    decode_oct_integer(:+, rest)
  end

  defp decode_term(<<"-0o", rest::binary>>) do
    decode_oct_integer(:-, rest)
  end

  defp decode_term(<<"0x", rest::binary>>) do
    decode_hex_integer(:_, rest)
  end

  defp decode_term(<<"+0x", rest::binary>>) do
    decode_hex_integer(:+, rest)
  end

  defp decode_term(<<"-0x", rest::binary>>) do
    decode_hex_integer(:-, rest)
  end

  defp decode_term("") do
    {:error, :no_term}
  end

  defp decode_term(term) when is_binary(term) do
    case decode_dec_integer(term) do
      {:ok, value} ->
        {:ok, value}

      {:error, _} ->
        case decode_float(term) do
          {:ok, value} ->
            {:ok, value}

          {:error, _} ->
            {:ok, %Value{value: term, type: :id}}
        end
    end
  end

  defp decode_bin_integer(sign, bin, state \\ :start, acc \\ [])

  defp decode_bin_integer(_sign, <<>>, :start, _acc) do
    {:error, :invalid_bin_integer_format}
  end

  defp decode_bin_integer(sign, <<"_", rest::binary>>, :body, acc) do
    decode_bin_integer(sign, rest, :body, acc)
  end

  defp decode_bin_integer(sign, <<c::utf8, rest::binary>>, _, acc) when c in [?0, ?1] do
    decode_bin_integer(sign, rest, :body, [<<c::utf8>> | acc])
  end

  defp decode_bin_integer(_sign, <<_::utf8, _rest::binary>>, _, _acc) do
    {:error, :invalid_bin_integer_format}
  end

  defp decode_bin_integer(sign, <<>>, :body, acc) do
    case decode_integer(sign, acc, 2) do
      {:ok, value} ->
        {:ok, %{value | format: :bin}}

      {:error, _} = err ->
        err
    end
  end

  defp decode_oct_integer(sign, bin, state \\ :start, acc \\ [])

  defp decode_oct_integer(_sign, <<>>, :start, _acc) do
    {:error, :invalid_oct_integer_format}
  end

  defp decode_oct_integer(sign, <<"_", rest::binary>>, :body, acc) do
    decode_oct_integer(sign, rest, :body, acc)
  end

  defp decode_oct_integer(sign, <<c::utf8, rest::binary>>, _, acc) when c in ?0..?7 do
    decode_oct_integer(sign, rest, :body, [<<c::utf8>> | acc])
  end

  defp decode_oct_integer(_sign, <<_::utf8, _rest::binary>>, _, _acc) do
    {:error, :invalid_oct_integer_format}
  end

  defp decode_oct_integer(sign, <<>>, :body, acc) do
    case decode_integer(sign, acc, 8) do
      {:ok, value} ->
        {:ok, %{value | format: :oct}}

      {:error, _} = err ->
        err
    end
  end

  defp decode_dec_integer(bin, state \\ :start, acc \\ [])

  defp decode_dec_integer(<<>>, :start, _acc) do
    {:error, :invalid_dec_integer_format}
  end

  defp decode_dec_integer(<<"_", rest::binary>>, :body, acc) do
    decode_dec_integer(rest, :body, acc)
  end

  defp decode_dec_integer(<<c::utf8, rest::binary>>, :start, acc) when c in [?+, ?-] do
    decode_dec_integer(rest, :start, [<<c::utf8>> | acc])
  end

  defp decode_dec_integer(<<c::utf8, rest::binary>>, _, acc) when c in ?0..?9 do
    decode_dec_integer(rest, :body, [<<c::utf8>> | acc])
  end

  defp decode_dec_integer(<<_::utf8, _rest::binary>>, _, _acc) do
    {:error, :invalid_dec_integer_format}
  end

  defp decode_dec_integer(<<>>, :body, acc) do
    case decode_integer(nil, acc, 10) do
      {:ok, value} ->
        {:ok, %{value | format: :dec}}

      {:error, _} = err ->
        err
    end
  end

  defp decode_hex_integer(sign, bin, state \\ :start, acc \\ [])

  defp decode_hex_integer(_sign, <<>>, :start, _acc) do
    {:error, :invalid_hex_integer_format}
  end

  defp decode_hex_integer(sign, <<"_", rest::binary>>, :body, acc) do
    decode_hex_integer(sign, rest, :body, acc)
  end

  defp decode_hex_integer(sign, <<c::utf8, rest::binary>>, _, acc) when c in ?0..?9 or
                                                                  c in ?A..?F or
                                                                  c in ?a..?f do
    decode_hex_integer(sign, rest, :body, [<<c::utf8>> | acc])
  end

  defp decode_hex_integer(_sign, <<_::utf8, _rest::binary>>, _, _acc) do
    {:error, :invalid_hex_integer_format}
  end

  defp decode_hex_integer(sign, <<>>, :body, acc) do
    case decode_integer(sign, acc, 16) do
      {:ok, value} ->
        {:ok, %{value | format: :hex}}

      {:error, _} = err ->
        err
    end
  end

  defp decode_integer(nil, acc, radix) do
    case Integer.parse(IO.iodata_to_binary(Enum.reverse(acc)), radix) do
      {int, ""} ->
        {:ok, %Value{value: int, type: :integer}}

      {_int, _} ->
        {:error, :invalid_integer_format}

      :error ->
        {:error, :invalid_integer_format}
    end
  end

  defp decode_integer(sign, acc, radix) do
    case decode_integer(nil, acc, radix) do
      {:ok, %Value{} = value} ->
        # handle the explicit sign, so why?
        # erlang otp27 introduced +0.0 and -0.0, so we need to handle those moving forward
        case sign do
          :_ -> {:ok, value}
          :+ -> {:ok, %{value | value: +value.value}}
          :- -> {:ok, %{value | value: -value.value}}
        end
      {:error, _} = err ->
        err
    end
  end

  defp decode_float(value) do
    case parse_float_string(value) do
      {:ok, value} ->
        case Decimal.parse(value) do
          {%Decimal{} = decimal, ""} ->
            {:ok, %Value{value: decimal, type: :float}}

          {%Decimal{}, _} ->
            {:error, :invalid_float_format}

          :error ->
            {:error, :invalid_float_format}
        end

      {:error, _} = err ->
        err
    end
  end

  defp handle_slashdashes([:slashdash, _term | tokens], acc) do
    handle_slashdashes(tokens, acc)
  end

  defp handle_slashdashes([:slashdash], acc) do
    handle_slashdashes([], acc)
  end

  defp handle_slashdashes([term | tokens], acc) do
    handle_slashdashes(tokens, [term | acc])
  end

  defp handle_slashdashes([], acc) do
    Enum.reverse(acc)
  end
end
