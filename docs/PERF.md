# Mesures de performance

Banc : fenêtre réelle affichée 10 s après 2 s de chauffe, CPU du processus (getrusage), build release, M4 Max. Le banc vit hors du dépôt (scratchpad de session) ; il réutilise les vues de l'app avec des données fictives, le panneau avec des relevés réels.

| Idée | Avant → après | Verdict | Pourquoi |
|---|---|---|---|
| Supprimer les animations infinies de la fenêtre (fond qui dérive, Mac qui flotte, anneau du bouton qui tourne) | Vibe Check 14,6 % → 0,0 % ; tuiles 13,1 % → 0,0 % | gardé | Une seule animation sans fin suffit à faire redessiner toute la fenêtre de verre à chaque image : 12 à 28 % chacune, mesurées séparément. L'anneau ne tourne plus qu'au survol. |
| Panneau de la barre des menus (relevés toutes les 2 s, processus toutes les 10 s) | 2,1–2,5 % ; 101 Mo stables sur 90 s | rien à changer | Pas de fuite, coût acceptable. |

Règle : pas d'animation `repeatForever` sur un écran qui reste affiché ; seulement pendant une action (analyse) ou un survol.
