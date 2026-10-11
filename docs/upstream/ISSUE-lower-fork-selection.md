# Select validated SSL and gRPC fork corrections

The released foundation selected canonical upstream SSL and gRPC source despite separately validated fork corrections. Package identity alone does not select fork source: the root manifest and resolved graph must name the intended repository and immutable revision.

Select Stephen's SSL `8f2f979a28610f47714d50eccfe16b435e7e04a5` and gRPC transport `44247d21352316e6ce3a39ba0f1f79ec39876c9f`. Keep canonical transitive declarations unchanged; selected Swift 6.4 resolves each identity once at the direct immutable root requirement. Synchronize the separate vminitd lock because its local SDK dependency inherits these requirements. No mirror, environment override, guest image substitution or build-system change is required.

Historical published archives and guest images remain immutable. A newly selected source graph requires fresh compiled foundation and downstream consumer evidence before release; host tests do not certify an existing guest image or Linux guest build.
