defmodule Bastion.Push.WebPush do
  @moduledoc """
  Web Push without extra libraries: the payload is encrypted for the browser with
  aes128gcm (RFC 8291) and the request is signed with a VAPID token (RFC 8292).
  """

  @record_size 4096

  def encrypt(payload, p256dh, auth, opts \\ []) do
    ua_public = decode64(p256dh)
    auth_secret = decode64(auth)

    {as_public, as_private} =
      Keyword.get_lazy(opts, :server_keys, fn -> :crypto.generate_key(:ecdh, :prime256v1) end)

    salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(16) end)

    shared = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)
    ikm = hkdf(auth_secret, shared, "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)
    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>>, 12)

    # A single record, so the padding delimiter is 0x02.
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, payload <> <<2>>, "", true)

    salt <> <<@record_size::32, byte_size(as_public)::8>> <> as_public <> ciphertext <> tag
  end

  def vapid_header(endpoint, {public, private}, subject, now \\ System.system_time(:second)) do
    %URI{scheme: scheme, host: host} = URI.parse(endpoint)

    input =
      encode64(Jason.encode!(%{typ: "JWT", alg: "ES256"})) <>
        "." <>
        encode64(Jason.encode!(%{aud: "#{scheme}://#{host}", exp: now + 12 * 3600, sub: subject}))

    der = :crypto.sign(:ecdsa, :sha256, input, [private, :prime256v1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    signature = <<r::unsigned-big-256, s::unsigned-big-256>>

    "vapid t=#{input}.#{encode64(signature)}, k=#{encode64(public)}"
  end

  def keys_from_seed(seed) do
    private = :crypto.mac(:hmac, :sha256, seed, "bastion web push vapid key")
    {public, ^private} = :crypto.generate_key(:ecdh, :prime256v1, private)
    {public, private}
  end

  def encode64(data), do: Base.url_encode64(data, padding: false)

  def decode64(data),
    do:
      data
      |> String.trim_trailing("=")
      |> String.replace(["+", "/"], fn
        "+" -> "-"
        "/" -> "_"
      end)
      |> Base.url_decode64!(padding: false)

  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    binary_part(:crypto.mac(:hmac, :sha256, prk, info <> <<1>>), 0, length)
  end
end
