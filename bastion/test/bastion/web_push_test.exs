defmodule Bastion.WebPushTest do
  use ExUnit.Case, async: true

  alias Bastion.Push.WebPush

  # The example of RFC 8291, section 5.
  test "encrypts the payload exactly like the RFC example" do
    as_public =
      WebPush.decode64(
        "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
      )

    as_private = WebPush.decode64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")

    body =
      WebPush.encrypt(
        "When I grow up, I want to be a watermelon",
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
        "BTBZMqHH6r4Tts7J_aSIgg",
        server_keys: {as_public, as_private},
        salt: WebPush.decode64("DGv6ra1nlYgDCS1FRnbzlw")
      )

    assert WebPush.encode64(body) ==
             "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
  end

  test "the vapid token is signed by the public key it carries" do
    {public, _private} = keys = WebPush.keys_from_seed("secret")

    header =
      WebPush.vapid_header("https://fcm.googleapis.com/fcm/send/abc", keys, "mailto:a@b.c", 1_000)

    [_, jwt, key] = Regex.run(~r/^vapid t=(\S+), k=(\S+)$/, header)
    assert WebPush.decode64(key) == public

    [head, claims, signature] = String.split(jwt, ".")

    assert %{"aud" => "https://fcm.googleapis.com", "exp" => 44_200} =
             Jason.decode!(WebPush.decode64(claims))

    <<r::unsigned-big-256, s::unsigned-big-256>> = WebPush.decode64(signature)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    assert :crypto.verify(:ecdsa, :sha256, head <> "." <> claims, der, [public, :prime256v1])
  end
end
